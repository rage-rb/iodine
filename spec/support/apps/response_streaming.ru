# Test app for HTTP response streaming.
# The body responds to `call(stream)` (Rack streaming body), so Iodine should
# hand it a RackStream writer and stream each chunk incrementally.
same_fiber = nil
release_channel = "response-streaming-release"

run ->(env) do
  if env['PATH_INFO'] == '/stream-state'
    next [200, {}, ["same_fiber=#{same_fiber}"]]
  end

  if env['PATH_INFO'] == '/release'
    Iodine.publish(release_channel, '', Iodine::PubSub::PROCESS)
    next [204, {}, []]
  end

  if env['PATH_INFO'] == '/async'
    body = proc do |stream|
      Iodine.subscribe(release_channel) do
        stream.write("marker-b\n")
        stream.close
        Iodine.defer { Iodine.unsubscribe(release_channel) }
      end
      stream.write("marker-a\n")
    end

    next [200, {}, body]
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
