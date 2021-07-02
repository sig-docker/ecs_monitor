(require [hy.contrib.walk [let]])
(import [functools [partial]]
        time)
(import docker
        docker.models.containers)

(defn get_mem_usages [client]
  (->> (client.containers.list)
       (map (partial docker.models.containers.Container.stats :stream False))
       (map (fn [s] {:id (get s "id")
                     :mem_usage (get s "memory_stats" "usage")}))
       list))

(let [client (docker.from_env)]
  (while True
    (print (get_mem_usages client))
    (time.sleep 30)))
