# Test app for HTTP response streaming.
# The body responds to `call(stream)` (Rack streaming body), so Iodine should
# hand it a RackStream writer and stream each chunk incrementally.
run ->(env) do
  body = proc do |stream|
    5.times do |i|
      stream.write("chunk-#{i}\n")
      sleep 0.05 # a gap so incremental delivery is observable
    end
    stream.close
  end

  [200, {}, body]
end
