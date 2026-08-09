require 'spec_helper'

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

  it 'serves a multi-part each body through the buffered non-streaming path' do
    response = http_get('/each-body')
    expect(response.status).to eq(200)
    expect(response.chunked?).to be(false)
    expect(response.headers['Content-Length']).to eq('12')
    expect(consume_body(response)).to eq('each-body-ok')
  end

  it 'serves a status-only response through the empty non-streaming path' do
    response = http_get('/status-only')
    expect(response.status).to eq(204)
    expect(response.headers.get('Transfer-Encoding')).to be_empty
    # Iodine's http_finish adds Content-Length: 0 to every header-only
    # response, including 204. RFC 9110 forbids it on 204; worth raising
    # upstream separately.
    expect(response.headers['Content-Length']).to eq('0')
    expect(response.headers.get('Content-Type')).to be_empty
    expect(consume_body(response)).to eq("")
  end

  it 'serves a plain request after a streamed response on the same connection' do
    http_client.persistent("http://localhost:#{server_port}") do |client|
      streamed = client.get('/')
      expect(streamed.status).to eq(200)
      expect(streamed.chunked?).to be(true)
      expect(streamed.headers['Connection']).to eq('keep-alive')
      expect(consume_body(streamed)).to eq(expected)

      plain = client.get('/each-body')
      expect(plain.status).to eq(200)
      expect(plain.chunked?).to be(false)
      expect(plain.headers['Content-Length']).to eq('12')
      expect(consume_body(plain)).to eq('each-body-ok')
    end
  end

  it 'treats close as idempotent and rejects writes after the terminal state' do
    http_client.persistent("http://localhost:#{server_port}") do |client|
      response = client.get('/double-close')
      expect(response.status).to eq(200)
      expect(response.chunked?).to be(true)
      expect(consume_body(response)).to eq('payload')

      followup = client.get('/each-body')
      expect(followup.status).to eq(200)
      expect(consume_body(followup)).to eq('each-body-ok')
    end

    result = consume_body(http_get('/double-close-result'))
    expect(result).to eq(
      'first_close=nil second_close=nil closed=true ' \
      'write_after_close=closed wake_channel=nil'
    )
  end

  it 'wakes a blocked producer when the outgoing queue drains' do
    response = http_get('/backpressure')

    wait_for_backpressure { |r| r =~ /would_blocks=[1-9]/ }

    expect(consume_body(response)).to eq('x' * (256 * 16_384))

    result = wait_for_backpressure do |r|
      r.include?('result=completed') && r.include?('unsubscribed=true')
    end
    expect(result).to match(
      /result=completed sent=256 would_blocks=[1-9]\d* wakes=[1-9]\d* finished=true unsubscribed=true/
    )
  end

  it 'wakes a blocked producer when another callback closes the stream' do
    # The body stays unconsumed until the server reports the close, so the
    # outgoing queue backs up and the producer blocks on its own.
    response = http_get('/backpressure-close')

    result = wait_for_backpressure(result_path: '/backpressure-close-result') do |r|
      r.include?('result=closed') && r.include?('unsubscribed=true')
    end
    expect(result).to match(
      %r{\Aresult=closed\s+sent=\d+\s+would_blocks=1\s+
         wakes=1\s+last_wake=close\s+close_scheduled=true\s+
         closed_externally=true\s+finished=true\s+unsubscribed=true\z}x
    )

    sent = result[/sent=(\d+)/, 1].to_i
    expect(response.status).to eq(200)
    expect(consume_body(response)).to eq('x' * (sent * 16_384))
  end

  it 'wakes a parked producer when the client disconnects mid-stream' do
    client = http_client
    client.get("http://localhost:#{server_port}/backpressure")

    wait_for_backpressure { |r| r =~ /would_blocks=[1-9]/ }
    client.close

    result = wait_for_backpressure do |r|
      r.include?('result=disconnected') && r.include?('unsubscribed=true')
    end
    expect(result).to match(/result=disconnected .*finished=true unsubscribed=true/)

    response = http_get('/te-write')
    expect(consume_body(response)).to eq('hello')
  end

  it 'isolates wake subscriptions for sequential streams on one connection' do
    expected_stream = 'x' * (256 * 16_384)

    http_client.persistent("http://localhost:#{server_port}") do |client|
      first = client.get('/backpressure')
      expect(first.status).to eq(200)
      expect(consume_body(first)).to eq(expected_stream)

      second = client.get('/backpressure')
      expect(second.status).to eq(200)
      expect(consume_body(second)).to eq(expected_stream)
    end
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
