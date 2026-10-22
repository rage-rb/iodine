run ->(env) do
  buffer = String.new
  env["rack.input"].read(1024, buffer)

  result = [buffer.encoding.name, buffer.ascii_only?, buffer.bytesize].join(":")
  [200, {}, [result]]
end
