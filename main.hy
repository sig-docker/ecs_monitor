(require [hy.contrib.walk [let]])
(import [datetime [datetime]]
        dateutil.parser
        [functools [partial]]
        [hy.contrib.pprint [pp pformat]]
        [os [environ]]
        time)
(import boto3
        cachetools
        docker
        docker.models.containers)
(import [util [chunks merge]])

(setv DEBUG (.get environ "ECS_MONITOR_DEBUG"))

(defn log [&rest args]
  (let [parts (->> args
                   (map (fn [a] (if (string? a) a (pformat a))))
                   list)]
    (print (datetime.strftime (datetime.now) "[%b %d, %Y %H:%M:%S]") (unpack-iterable parts))))

(defn debug [&rest args]
  (when DEBUG (log #* args)))

(defn nap [&optional [seconds 300]]
  (debug "Sleeping" seconds "seconds")
  (time.sleep seconds))

(defn boto-client [name]
  (-> (boto3.session.Session)
      (.client name)))

(defn get-mem-usages-real [client]
  (->> (client.containers.list)
       (map (partial docker.models.containers.Container.stats :stream False))
       (map (fn [s] {:id (get s "id")
                     :time (get s "read")
                     :mem-usage (get s "memory_stats" "usage")}))
       list))

(setv RUNTIME-ID "40b2cf8b1a76358d3ae6210b1050d249ca2b28cf0152afc57a97097514664a5f")
(defn get-mem-usages-testing [data-file client]
  (debug "Loading test data from:" data-file)
  (with [fp (open data-file "r")]
    (hy.eval (hy.read fp))))

(setv get-mem-usages (let [data-file (.get environ "ECS_MONITOR_DOCKER_DATAFILE")]
                       (if data-file (partial get-mem-usages-testing data-file)
                           get-mem-usages-real)))

(defn get-task-arns [client cluster-arn &optional container-inst-arn]
  (let [pager (client.get_paginator "list_tasks")]
    ;; TODO: There's bound to be a more elegant, LISP-y way to do this, maybe with partial application.
    ;;       The boto3 API doesn't like you to pass None for undefined keyword args.
    (for [page (if container-inst-arn
                   (.paginate pager :cluster cluster-arn :containerInstance container-inst-arn)
                   (.paginate pager :cluster cluster-arn))]
      (for [task-arn (get page "taskArns")]
        (yield task-arn)))))

(defn get-tasks [client cluster-arn &optional container-inst-arn]
  (for [arns (chunks (get-task-arns client cluster-arn container-inst-arn) 100)]
    (for [task (-> client
                   (.describe_tasks :cluster cluster-arn :tasks arns)
                   (get "tasks"))]
      (yield task))))

(defn get-containers [client cluster-arn &optional container-inst-arn]
  (for [task (get-tasks client cluster-arn container-inst-arn) :if (in "containerInstanceArn" task)]
    (for [container (get task "containers") :if (in "runtimeId" container)]
      (yield {:group (get task "group")
              :runtime-id (get container "runtimeId")
              :container-name (get container "name")
              :container-instance-arn (get task "containerInstanceArn")}))))

(defn update-cache [cache client cluster-arn &optional container-inst-arn]
  (log "Updating container cache...")
  (for [container (get-containers client cluster-arn container-inst-arn)]
    (let [runtime-id (:runtime-id container)]
      (debug "Caching:" runtime-id "->\n" container "\n")
      (assoc cache (:runtime-id container) container)))
  (debug "Cache size:" cache.currsize "/" cache.maxsize))

(defn discover-container-instance-arn [cache docker-client cluster-arn]
  (let [ecs-client (boto-client "ecs")]
    (while True
      (log "Attempting to determine which container instance I'm running on...")

      (update-cache cache ecs-client cluster-arn)
      (let [ret (->> (get-mem-usages docker-client)
                     (map ':id)
                     (map (fn [s] (.get cache s)))
                     (drop-while none?)
                     (map ':container-instance-arn)
                     first)]
        (if ret (return ret)))
      (log "Unable to determine my container instance ID.")
      (nap))))

(defn get-container-stats [cache docker-client ecs-client cluster-arn container-inst-arn &optional no-refresh]
  (let [first-pass (->> (get-mem-usages docker-client)
                        (map (fn [s] (merge s (.get cache (:id s) {}))))
                        list)]
    ;; If there are some un-matched containers, refresh the cache and recurse. If not (or we've already
    ;; recursed) just return what we have. That way we only attempt to refresh the cache one time.
    (if (and (not no-refresh) (some (fn [s] (not (in :group s))) first-pass))
        (do (update-cache cache ecs-client cluster-arn container-inst-arn)
            (return (get-container-stats cache docker-client ecs-client cluster-arn container-inst-arn True)))
        (return first-pass))))

(defn get-valid-stats [cache docker-client ecs-client cluster-arn container-inst-arn]
  (for [s (get-container-stats cache docker-client ecs-client cluster-arn container-inst-arn)]
    ;; If the stat has service details, yield it. Othewise it's a container without a service so we'll mark
    ;; it in the cache and move on. That way we don't keep refreshing the cache over non-service containers.
    (if (in :group s) (yield s)
        (assoc cache (:id s) {}))))

(defn parse-time [s]
  (dateutil.parser.isoparse s))

(defn to-metric-data [cluster-name s]
  {"MetricName" "MemoryUsage"
   "Dimensions" [{"Name" "ClusterName" "Value" cluster-name}
                 {"Name" "Group" "Value" (:group s)}
                 {"Name" "ContainerName" "Value" (:container-name s)}]
   "Timestamp" (parse-time (:time s))
   "Value" (:mem-usage s)
   "Unit" "Bytes"})

(defn put-metrics [client metrics]
  (debug "Putting metric data\n" metrics)
  (.put_metric_data client :Namespace "ECS/Monitor" :MetricData metrics))

(defn get-cluster-name [arn]
  (debug "Fetching name of cluster" arn)
  (let [cluster-name
        (-> (boto-client "ecs")
            (.describe_clusters :clusters [arn])
            (.get "clusters")
            first
            (.get "clusterName"))]
    (log "cluster-name:" cluster-name)
    cluster-name))

(defn apply-in-chunks [chunk-size f it]
  (for [chunk (chunks it chunk-size)]
    (f chunk)))

(defn run-once [cache docker-client cluster-arn cluster-name container-inst-id]
  (let [boto-session (boto3.session.Session)
        ecs-client (.client boto-session "ecs")
        cw-client (.client boto-session "cloudwatch")]
    (->> (get-valid-stats cache docker-client ecs-client cluster-arn container-inst-id)
         (map (partial to-metric-data cluster-name))
         (apply-in-chunks 20 (partial put-metrics cw-client)))))

(defn main-loop [cluster-arn]
  (let [cache (cachetools.LRUCache :maxsize 4096)
        cluster-name (get-cluster-name cluster-arn)
        docker-client (docker.from_env)
        container-inst-id (discover-container-instance-arn cache docker-client cluster-arn)]
    (while True
      (run-once cache docker-client cluster-arn cluster-name container-inst-id)
      (nap))))

(let [cluster-arn (.get environ "CLUSTER_ARN")]
  (if cluster-arn (main-loop cluster-arn)
      (raise (Exception "Missing required environment variable: CLUSTER_ARN"))))
