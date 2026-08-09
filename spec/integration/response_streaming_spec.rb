require 'spec_helper'
require 'timeout'

# Functional tests for HTTP response streaming: a real Iodine server runs the
# `response_streaming` app and the HTTP gem consumes the response incrementally.
RSpec.describe 'HTTP response streaming', with_app: :response_streaming do
  let(:expected) { "chunk-0\nchunk-1\nchunk-2\nchunk-3\nchunk-4\n" }

  def consume_body(response)
    body = +""
    response.body.each { |fragment| body << fragment }
    body
  end

  def backpressure_result(path = '/backpressure-result')
    consume_body(http_get(path))
  end

  def wait_for_backpressure(deadline: 10, result_path: '/backpressure-result')
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      result = backpressure_result(result_path)
      return result if yield(result)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - start > deadline
        raise "timed out waiting for backpressure state, last: #{result}"
      end
      sleep 0.05
    end
  end

  def read_chunked_response(socket)
    status = socket.gets("\r\n")
    raise EOFError, 'connection closed before response status' unless status

    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.delete_suffix("\r\n").split(':', 2)
      headers[name.downcase] = value&.strip
    end
    raise EOFError, 'connection closed before response headers completed' unless line
    unless headers['transfer-encoding'] == 'chunked'
      raise "expected chunked response, got #{headers.inspect}"
    end

    body = +""
    loop do
      size_line = socket.gets("\r\n")
      raise EOFError, 'connection closed before chunk size' unless size_line

      size = size_line.split(';', 2).first.to_i(16)
      if size.zero?
        loop do
          trailer = socket.gets("\r\n")
          unless trailer
            raise EOFError, 'connection closed before chunk trailers completed'
          end
          break if trailer == "\r\n"
        end
        break
      end

      chunk = socket.read(size)
      unless chunk&.bytesize == size
        raise EOFError, 'connection closed inside response chunk'
      end
      raise 'invalid chunk terminator' unless socket.read(2) == "\r\n"
      body << chunk
    end

    [status, body]
  end

  it 'responds 200 and reassembles the full streamed body' do
    response = http_get("/")
    expect(response.status).to eq(200)
    expect(consume_body(response)).to eq(expected)
  end

  it 'invokes the callable body in the current Fiber' do
    response = http_get("/")
    expect(consume_body(response)).to eq(expected)

    state = http_get('/stream-state')
    expect(consume_body(state)).to eq('same_fiber=true')
  end

  it 'uses chunked transfer encoding, not Content-Length' do
    response = http_get("/")
    expect(response.chunked?).to be(true)
    expect(response.headers).not_to include('Content-Length')
    expect(consume_body(response)).to eq(expected)
  end

  it 'delivers chunks incrementally rather than buffering the whole response' do
    first_seen = {}
    buf = +""

    response = http_get("/")
    response.body.each do |fragment|
      observed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      buf << fragment
      5.times do |i|
        first_seen[i] ||= observed_at if buf.include?("chunk-#{i}\n")
      end
    end

    expect(buf).to eq(expected)
    expect(first_seen.keys.sort).to eq([0, 1, 2, 3, 4])
    expect(first_seen[4] - first_seen[0]).to be > 0.1
  end

  it 'strips a conflicting application-supplied Content-Length' do
    response = http_get('/conflicting-length')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(true)
    expect(response.headers).not_to include('Content-Length')
    expect(consume_body(response)).to eq('hello world')
  end

  it 'strips an application-supplied Transfer-Encoding when the stream closes without writing' do
    response = http_get('/te-no-write')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(false)
    expect(response.headers.get('Transfer-Encoding')).to be_empty
    expect(response.headers['Content-Length']).to eq('0')
    expect(consume_body(response)).to eq("")
  end

  it 'strips application-supplied framing headers when an oversized write fails the stream' do
    response = http_get('/framing-oversized')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(false)
    expect(response.headers.get('Transfer-Encoding')).to be_empty
    expect(response.headers['Content-Length']).to eq('0')
    expect(consume_body(response)).to eq("")
  end

  it 'sends exactly one Transfer-Encoding: chunked on a successful write' do
    response = http_get('/te-write')
    expect(response.status).to eq(200)
    expect(response.headers.get('Transfer-Encoding')).to eq(['chunked'])
    expect(response.headers.get('Content-Length')).to be_empty
    expect(consume_body(response)).to eq('hello')
  end

  it 'completes a stream closed without writing as a normal empty response' do
    response = http_get('/no-write')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(false)
    expect(response.headers['Content-Length']).to eq('0')
    expect(consume_body(response)).to eq("")
  end

  it 'starts chunked framing on an explicit empty first write' do
    response = http_get('/empty-write')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(true)
    expect(response.headers).not_to include('Content-Length')
    expect(consume_body(response)).to eq("")
  end

  it 'completes the response cleanly after an oversized write fails the stream' do
    response = http_get('/oversized')
    expect(response.status).to eq(200)
    expect(consume_body(response)).to eq("")

    result = http_get('/oversized-result')
    expect(consume_body(result)).to eq('result=error')
  end

  it 'wakes a blocked producer when the outgoing queue drains' do
    response = http_get('/backpressure')

    wait_for_backpressure { |r| r =~ /would_blocks=[1-9]/ }

    expect(consume_body(response)).to eq('x' * (256 * 16_384))

    result = wait_for_backpressure { |r| r.include?('result=completed') }
    expect(result).to match(/result=completed sent=256 would_blocks=[1-9]\d* wakes=[1-9]\d*/)
  end

  it 'wakes a blocked producer when another callback closes the stream' do
    socket = Socket.tcp('localhost', server_port)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 16_384)
    socket.write("GET /backpressure-close HTTP/1.1\r\nHost: localhost\r\n\r\n")

    result = wait_for_backpressure(result_path: '/backpressure-close-result') do |r|
      r.include?('result=closed') && r.include?('unsubscribed=true')
    end
    expect(result).to match(
      %r{\Aresult=closed\s+sent=\d+\s+would_blocks=1\s+
         wakes=1\s+last_wake=close\s+close_scheduled=true\s+
         closed_externally=true\s+finished=true\s+unsubscribed=true\z}x
    )

    status, body = Timeout.timeout(10) { read_chunked_response(socket) }
    sent = result[/sent=(\d+)/, 1].to_i
    expect(status).to start_with('HTTP/1.1 200')
    expect(body).to eq('x' * (sent * 16_384))
  ensure
    socket&.close
  end

  it 'wakes a parked producer when the client disconnects mid-stream' do
    sock = Socket.tcp('localhost', server_port)
    begin
      sock.write("GET /backpressure HTTP/1.1\r\nHost: localhost\r\n\r\n")

      wait_for_backpressure { |r| r =~ /would_blocks=[1-9]/ }
    ensure
      sock.close
    end

    result = wait_for_backpressure { |r| r.include?('result=disconnected') }
    expect(result).to match(/result=disconnected/)

    response = http_get('/te-write')
    expect(consume_body(response)).to eq('hello')
  end

  it 'isolates wake subscriptions for pipelined streams on one connection' do
    socket = Socket.tcp('localhost', server_port)
    responses = Timeout.timeout(15) do
      socket.write(
        "GET /backpressure HTTP/1.1\r\nHost: localhost\r\n\r\n" \
        "GET /backpressure HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )
      [read_chunked_response(socket), read_chunked_response(socket)]
    end

    expected = 'x' * (256 * 16_384)
    expect(responses.map(&:first)).to all(start_with('HTTP/1.1 200'))
    expect(responses.map(&:last)).to eq([expected, expected])
  ensure
    socket&.close
  end

  it 'keeps streaming after the callable returns' do
    body = +""
    released = false

    response = http_get('/async')
    response.body.each do |fragment|
      body << fragment
      next if released || !body.include?("marker-a\n")

      released = true
      expect(http_get('/release').status).to eq(204)
    end

    expect(released).to be(true)
    expect(body).to eq("marker-a\nmarker-b\n")
  end
end
