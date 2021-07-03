(require [hy.contrib.walk [let]])
(import [functools [partial]]
        [hy.contrib.pprint [pp]]
        time)
(import boto3
        cachetools
        docker
        docker.models.containers)
(import [util [chunks merge]])

#_(import yaml)

(defn nap [&optional [seconds 30]]
  (print "Sleeping" seconds "seconds")
  (time.sleep seconds))

#_(defn get-mem-usages [client]
  (->> (client.containers.list)
       (map (partial docker.models.containers.Container.stats :stream False))
       (map (fn [s] {:id (get s "id")
                     :time (get s "read")
                     :mem_usage (get s "memory_stats" "usage")}))
       list))

(setv RUNTIME-ID "40b2cf8b1a76358d3ae6210b1050d249ca2b28cf0152afc57a97097514664a5f")
(defn get-mem-usages [client]
  [{:id "bad" #_RUNTIME-ID
    :time "2021-07-03T14:26:23.123123"
    :mem_usage 14876672}
   {:id RUNTIME-ID
    :time "2021-07-03T14:26:23.123123"
    :mem_usage 14876672}])

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
  (for [task (get-tasks client cluster-arn container-inst-arn)]
    (for [container (get task "containers")]
      (yield {:group (get task "group")
              :runtime-id (get container "runtimeId")
              :container-name (get container "name")
              :container-instance-arn (get task "containerInstanceArn")}))))

(defn update-cache [cache client cluster-arn &optional container-inst-arn]
  (print "Updating container cache...")
  (for [container (get-containers client cluster-arn container-inst-arn)]
    (assoc cache (:runtime-id container) container)))

(defn discover-container-instance-arn [cache docker-client ecs-client cluster-arn]
  (while True
    (print "Attempting to determine which container instance I'm running on...")
    (update-cache cache ecs-client cluster-arn)
    (let [ret (->> (get-mem-usages docker-client)
                   (map ':id)
                   (map (fn [s] (.get cache s)))
                   (drop-while none?)
                   (map ':container-instance-arn)
                   first)]
      (if ret (return ret)))
    (print "Unable to determine my container instance ID.")
    (nap)))

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

(defn put-metric [client s]
  (print "Putting metric:")
  (pp s))

(let [cache (cachetools.LRUCache :maxsize 4096)
      ecs-client (boto3.client "ecs")
      cw-client (boto3.client "cloudwatch")
      docker-client (docker.from_env)
      cluster-arn "arn:aws:ecs:us-east-2:875565619567:cluster/ban-nonprod"
      container-inst-id (discover-container-instance-arn cache docker-client ecs-client cluster-arn)]
  (while True
    (for [s (->> (get-valid-stats cache docker-client ecs-client cluster-arn container-inst-id))]
      (put-metric cw-client s))
    (nap)))

#_(let [client (docker.from_env)]
  (while True
    (pp (get-mem-usages client))
    (time.sleep 30)))
