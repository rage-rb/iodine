# Test app for HTTP response streaming.
# The body responds to `call(stream)` (Rack streaming body), so Iodine should
# hand it a RackStream writer and stream each chunk incrementally.
same_fiber = nil

run ->(env) do
  if env['PATH_INFO'] == '/stream-state'
    next [200, {}, ["same_fiber=#{same_fiber}"]]
  end

  request_fiber = Fiber.current
  body = proc do |stream|
    same_fiber = Fiber.current.equal?(request_fiber)
    5.times do |i|
      stream.write("chunk-#{i}\n")
      sleep 0.05 # a gap so incremental delivery is observable
    end
    stream.close
  end

  [200, {}, body]
end
