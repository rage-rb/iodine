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
end
