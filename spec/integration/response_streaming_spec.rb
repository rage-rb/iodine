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
