# Test app that produces faster than a slow client can read, so the producer is
# pushed past the HIGH watermark and must handle :would_block by yielding.
run ->(env) do
  body = proc do |stream|
    payload = "x" * 16_000
    total = 128
    total.times do
      loop do
        case stream.write(payload)
        when :ok then break
        when :would_block then Fiber.yield
        else break
        end
      end
    end
    stream.close
  end

  [200, {}, body]
end
