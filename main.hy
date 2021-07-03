(require [hy.contrib.walk [let]])
(import [functools [partial]]
        [hy.contrib.pprint [pp]]
        time)
(import boto3
        cachetools
        docker
        docker.models.containers)
(import [util [chunks]])

(import yaml)

(defn get-mem-usages [client]
  (->> (client.containers.list)
       (map (partial docker.models.containers.Container.stats :stream False))
       (map (fn [s] {:id (get s "id")
                     :mem_usage (get s "memory_stats" "usage")}))
       list))

(defn get-task-arns [client cluster-arn]
  (for [page (.paginate (client.get_paginator "list_tasks") :cluster cluster-arn)]
    (for [task-arn (get page "taskArns")]
      (yield task-arn))))

(defn get-tasks [client cluster-arn]
  (for [arns (chunks (get-task-arns client cluster-arn) 100)]
    (for [task (-> client
                   (.describe_tasks :cluster cluster-arn :tasks arns)
                   (get "tasks"))]
      (yield task))))

(defn get-containers [client cluster-arn]
  (for [task (get-tasks client cluster-arn)]
    #_(-> task
        (get "containers")
        yaml.dump print)
    (for [container (get task "containers")]
      #_(-> container yaml.dump print)
      (yield {:group (get task "group")
              :runtime-id (get container "runtimeId")
              :container-instance-arn (get task "containerInstanceArn")}))))

(let [cache (cachetools.LRUCache :maxsize 4096)
      ecs-client (boto3.client "ecs")
      cluster-arn "arn:aws:ecs:us-east-2:875565619567:cluster/ban-nonprod"]
  (-> (get-containers ecs-client cluster-arn)
      list pp))

#_(let [client (docker.from_env)]
  (while True
    (print (get-mem-usages client))
    (time.sleep 30)))
