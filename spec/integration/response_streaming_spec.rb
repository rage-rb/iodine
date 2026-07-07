require 'spec_helper'
require 'socket'

# Functional tests for HTTP response streaming: a real Iodine server runs the
# `response_streaming` app and we assert on the wire behavior end to end.
RSpec.describe 'HTTP response streaming', with_app: :response_streaming do
  let(:expected) { "chunk-0\nchunk-1\nchunk-2\nchunk-3\nchunk-4\n" }

  # Sends a raw GET and returns [raw_headers_string, chunk_arrival_times].
  def raw_stream_get
    times = []
    headers = +""
    Socket.tcp('localhost', server_port, connect_timeout: 1) do |sock|
      sock.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
      buf = +""
      loop do
        begin
          data = sock.read_nonblock(4096)
          times << Time.now
          buf << data
        rescue IO::WaitReadable
          break unless IO.select([sock], nil, nil, 2)
          retry
        rescue EOFError
          break
        end
      end
      headers = buf.split("\r\n\r\n", 2).first.to_s
    end
    [headers, times]
  end

  it 'responds 200 and reassembles the full streamed body' do
    response = http_get("/")
    expect(response.status).to eq(200)
    expect(response.body.to_s).to eq(expected)
  end

  it 'uses chunked transfer encoding, not Content-Length' do
    headers, = raw_stream_get
    expect(headers.downcase).to match(/transfer-encoding:\s*chunked/)
    expect(headers.downcase).not_to include("content-length:")
  end

  it 'delivers chunks incrementally rather than buffering the whole response' do
    _, times = raw_stream_get
    expect(times.length).to be > 1
    # 5 chunks written 0.05s apart -> arrivals must span well beyond a single read
    expect(times.last - times.first).to be > 0.1
  end
end
