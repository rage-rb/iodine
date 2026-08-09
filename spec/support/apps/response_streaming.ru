# Test app for HTTP response streaming.
# The body responds to `call(stream)` (Rack streaming body), so Iodine should
# hand it a RackStream writer and stream each chunk incrementally.
same_fiber = nil
oversized_result = nil
release_channel = "response-streaming-release"
backpressure = nil
backpressure_close = nil

run ->(env) do
  if env['PATH_INFO'] == '/stream-state'
    next [200, {}, ["same_fiber=#{same_fiber}"]]
  end

  if env['PATH_INFO'] == '/release'
    Iodine.publish(release_channel, '', Iodine::PubSub::PROCESS)
    next [204, {}, []]
  end

  if env['PATH_INFO'] == '/conflicting-length'
    body = proc do |stream|
      stream.write("hello ")
      stream.write("world")
      stream.close
    end

    next [200, { 'Content-Length' => '999' }, body]
  end

  if env['PATH_INFO'] == '/no-write'
    body = proc do |stream|
      stream.close
    end

    next [200, { 'Content-Length' => '5' }, body]
  end

  if env['PATH_INFO'] == '/te-no-write'
    body = proc do |stream|
      stream.close
    end

    next [200, { 'Transfer-Encoding' => 'chunked' }, body]
  end

  if env['PATH_INFO'] == '/te-write'
    body = proc do |stream|
      stream.write("hello")
      stream.close
    end

    next [200, { 'Transfer-Encoding' => 'chunked' }, body]
  end

  if env['PATH_INFO'] == '/framing-oversized'
    body = proc do |stream|
      stream.write("x" * (2 * 1024 * 1024))
      stream.close
    end

    next [200, { 'Transfer-Encoding' => 'chunked', 'Content-Length' => '999' }, body]
  end

  if env['PATH_INFO'] == '/empty-write'
    body = proc do |stream|
      stream.write("")
      stream.close
    end

    next [200, {}, body]
  end

  if env['PATH_INFO'] == '/oversized'
    body = proc do |stream|
      oversized_result = stream.write("x" * (2 * 1024 * 1024))
      stream.close
    end

    next [200, {}, body]
  end

  if env['PATH_INFO'] == '/oversized-result'
    next [200, {}, ["result=#{oversized_result}"]]
  end

  if ['/backpressure', '/backpressure-close'].include?(env['PATH_INFO'])
    close_while_blocked = env['PATH_INFO'] == '/backpressure-close'
    state = {
      result: nil,
      sent: 0,
      would_blocks: 0,
      wakes: 0,
      last_wake: nil,
      finished: false,
      unsubscribed: false
    }
    if close_while_blocked
      backpressure_close = state
    else
      backpressure = state
    end

    body = proc do |stream|
      payload = "x" * 16_384
      total = 256

      producer = Fiber.new do
        sent = 0
        while sent < total
          case (status = stream.write(payload))
          when :ok
            sent += 1
            state[:sent] = sent
          when :would_block
            state[:would_blocks] += 1
            Fiber.yield
            state[:wakes] += 1
          else
            state[:result] = status
            break
          end
        end
        state[:result] ||= :completed
        stream.close
        state[:finished] = true
      end

      channel = stream.wake_channel
      Iodine.subscribe(channel) do |_, message|
        state[:last_wake] = message
        producer.resume if producer.alive?
        unless producer.alive?
          Iodine.defer do
            removed = Iodine.unsubscribe(channel)
            state[:unsubscribed] = removed && !Iodine.subscribed?(channel)
          end
        end
      end

      if close_while_blocked
        state[:close_scheduled] = true
        Iodine.defer do
          producer.resume
          if producer.alive? && state[:would_blocks] > 0
            state[:closed_externally] = true
            stream.close
          elsif !producer.alive?
            Iodine.defer do
              removed = Iodine.unsubscribe(channel)
              state[:unsubscribed] = removed && !Iodine.subscribed?(channel)
            end
          end
        end
      else
        producer.resume
        unless producer.alive?
          Iodine.defer do
            removed = Iodine.unsubscribe(channel)
            state[:unsubscribed] = removed && !Iodine.subscribed?(channel)
          end
        end
      end
    end

    next [200, {}, body]
  end

  if env['PATH_INFO'] == '/backpressure-result'
    s = backpressure || {}
    next [200, {}, ["result=#{s[:result]} sent=#{s[:sent]} would_blocks=#{s[:would_blocks]} wakes=#{s[:wakes]}"]]
  end

  if env['PATH_INFO'] == '/backpressure-close-result'
    s = backpressure_close || {}
    next [200, {}, [
      "result=#{s[:result]} sent=#{s[:sent]} would_blocks=#{s[:would_blocks]} " \
      "wakes=#{s[:wakes]} last_wake=#{s[:last_wake]} " \
      "close_scheduled=#{s[:close_scheduled]} closed_externally=#{s[:closed_externally]} " \
      "finished=#{s[:finished]} unsubscribed=#{s[:unsubscribed]}"
    ]]
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
