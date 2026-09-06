require 'fcntl'

RSpec.describe Iodine::Scheduler do
  before do
    skip 'IO::Buffer is not available' unless defined?(IO::Buffer)
  end

  def with_pipe
    reader, writer = IO.pipe
    yield reader, writer
  ensure
    reader&.close
    writer&.close
  end

  def with_buffer(size)
    buffer = IO::Buffer.new(size)
    yield buffer
  ensure
    buffer&.free
  end

  describe '.read' do
    it 'writes directly into an IO::Buffer at the requested offset' do
      with_pipe do |reader, writer|
        with_buffer(8) do |buffer|
          buffer.set_string('........')
          writer.write('data')

          result = described_class.read(reader.fileno, buffer, 4, 2)

          expect(result).to eq(4)
          expect(buffer.get_string).to eq('..data..')
        end
      end
    end

    it 'returns the error from a read that would block' do
      with_pipe do |reader, _writer|
        with_buffer(1) do |buffer|
          flags = reader.fcntl(Fcntl::F_GETFL)
          reader.fcntl(Fcntl::F_SETFL, flags | Fcntl::O_NONBLOCK)

          result = described_class.read(reader.fileno, buffer, 1, 0)

          expect(result).to satisfy('be EAGAIN or EWOULDBLOCK') do |value|
            [-Errno::EAGAIN::Errno, -Errno::EWOULDBLOCK::Errno].include?(value)
          end
        end
      end
    end

    if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('4.1')
      it 'treats a zero length as a zero-length operation' do
        with_pipe do |reader, writer|
          with_buffer(4) do |buffer|
            buffer.set_string('....')
            writer.write('data')

            expect(described_class.read(reader.fileno, buffer, 0, 0)).to eq(0)
            expect(buffer.get_string).to eq('....')
          end
        end
      end
    else
      it 'uses the remaining buffer capacity when the length is zero' do
        with_pipe do |reader, writer|
          with_buffer(6) do |buffer|
            writer.write('data')

            expect(described_class.read(reader.fileno, buffer, 0, 2)).to eq(4)
            expect(buffer.get_string(2, 4)).to eq('data')
          end
        end
      end
    end
  end

  describe '.write' do
    it 'reads directly from an IO::Buffer at the requested offset' do
      with_pipe do |reader, writer|
        with_buffer(8) do |buffer|
          buffer.set_string('xxdata')

          result = described_class.write(writer.fileno, buffer, 4, 2)

          expect(result).to eq(4)
          expect(reader.read(4)).to eq('data')
        end
      end
    end

    it 'returns the error from a single write that would block' do
      with_pipe do |_reader, writer|
        with_buffer(1) do |buffer|
          buffer.set_string('x')
          chunk = 'x' * 4096
          loop do
            break if writer.write_nonblock(chunk, exception: false) == :wait_writable
          end

          result = described_class.write(writer.fileno, buffer, 1, 0)

          expect(result).to satisfy('be EAGAIN or EWOULDBLOCK') do |value|
            [-Errno::EAGAIN::Errno, -Errno::EWOULDBLOCK::Errno].include?(value)
          end
        end
      end
    end
  end

  describe '.write_async' do
    it 'queues data directly from an IO::Buffer at the requested offset' do
      with_pipe do |reader, writer|
        with_buffer(8) do |buffer|
          buffer.set_string('xxdata')

          result = described_class.write_async(writer.fileno, buffer, 4, 2)
          described_class.close

          expect(result).to eq(4)
          expect(reader.read(4)).to eq('data')
        end
      end
    end
  end

  describe 'buffer ranges' do
    it 'rejects slices which extend beyond the IO::Buffer' do
      with_pipe do |reader, writer|
        with_buffer(4) do |buffer|
          expect(described_class.read(reader.fileno, buffer, 3, 2)).to eq(-Errno::EINVAL::Errno)
          expect(described_class.write(writer.fileno, buffer, 3, 2)).to eq(-Errno::EINVAL::Errno)
          expect(described_class.write_async(writer.fileno, buffer, 3, 2)).to eq(-Errno::EINVAL::Errno)
        end
      end
    end
  end
end
