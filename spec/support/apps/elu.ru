require "iodine"

# Enable before workers fork, then age the parent window so the fork-reset
# test can tell inherited history (>= 600ms) from a fresh window (~ms).
Iodine::Perf.elu_enable_idle_time!
sleep 0.6

run(->(env) do
  case env["PATH_INFO"]
  when "/snapshot"
    idle, elapsed = Iodine::Perf.elu_snapshot
    [200, { "Content-Type" => "text/plain" },
     ["#{idle} #{elapsed}"]]
  when "/block"
    # Block the reactor : this is active time, not provider idle time.
    sleep 0.3
    [200, { "Content-Type" => "text/plain" }, ["blocked"]]
  else
    [200, { "Content-Type" => "text/plain" }, ["ok"]]
  end
end)
