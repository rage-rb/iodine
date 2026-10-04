# frozen_string_literal: true

RSpec.describe Iodine::Rack::Utils do
  describe "#parse_nested_query" do
    subject { described_class.parse_nested_query(q) }

    context "with one plain param" do
      let(:q) { "name=ross" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross" })
      end
    end

    context "with multiple plain params" do
      let(:q) { "name=ross&occupation=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", occupation: "paleontologist" })
      end
    end

    context "with array" do
      let(:q) { "names[]=ross&names[]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ names: %w(ross chandler) })
      end
    end

    context "with hash" do
      let(:q) { "users[name]=ross" }

      it "works correctly" do
        expect(subject).to eq({ users: { name: "ross" } })
      end
    end

    context "with hash with multiple values" do
      let(:q) { "users[name]=ross&users[occupation]=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ users: { name: "ross", occupation: "paleontologist" } })
      end
    end

    context "with nested arrays" do
      let(:q) { "users[][]=ross&users[][]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [%w(ross), %w(chandler)] })
      end
    end

    context "with hash nested inside array" do
      let(:q) { "users[][name]=ross" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ name: "ross" }] })
      end
    end

    context "with longer hash nested inside array" do
      let(:q) { "users[][name]=ross&users[][name]=chandler&users[][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ name: "ross" }, { name: "chandler" }, { name: "joey" }] })
      end
    end

    context "with array nested inside hash" do
      let(:q) { "ross[friends][]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: %w(chandler) } })
      end
    end

    context "with longer array nested inside hash" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[friends][]=monica" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: %w(chandler joey monica) } })
      end
    end

    context "with array nested inside multiple hashes" do
      let(:q) { "users[ross][friends][]=chandler&users[ross][friends][]=chandlers-mom" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: { friends: %w(chandler chandlers-mom) } } })
      end
    end

    context "with hash nested inside hash" do
      let(:q) { "ross[friend][name]=chandler&chandler[friend][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friend: { name: "chandler" } }, chandler: { friend: { name: "joey" } } })
      end
    end

    context "with mixed types" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ users: { user: { id: "11", name: "ross", friends: [{ id: "22", name: "chandler" }, { id: "33", name: "joey" }] } } })
      end
    end

    context "with hash with repeated attributes nested inside array" do
      let(:q) { "users[][id]=11&users[][name]=ross&users[][id]=22&users[][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ id: "11", name: "ross" }, { id: "22", name: "chandler" }] })
      end
    end

    context "with hash with mixed attributes nested inside array" do
      let(:q) { "users[][id]=11&users[][name]=ross&users[][id]=22&users[][full_name]=chandler-bing" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ id: "11", name: "ross" }, { id: "22", full_name: "chandler-bing" }] })
      end
    end

    context "with multi-level hash with mixed attributes nested inside array" do
      let(:q) { "users[][data][id]=11&users[][data][name]=ross&users[][data][id]=22&users[][data][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end

    context "with blank values" do
      let(:q) { "users=" }

      it "works correctly" do
        expect(subject).to eq({ users: "" })
      end
    end

    context "with blank array values" do
      let(:q) { "users[]" }

      it "works correctly" do
        expect(subject).to eq({ users: [""] })
      end
    end

    context "with blank hash values" do
      let(:q) { "users[ross]" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: "" } })
      end
    end

    context "with no values" do
      let(:q) { "users" }

      it "works correctly" do
        expect(subject).to eq({ users: nil })
      end
    end

    context "with overlapping params" do
      let(:q) { "name=ross&name=chandler" }

      it "works correctly" do
        expect(subject).to eq({ name: "chandler" })
      end
    end

    context "with missing params" do
      let(:q) { "name=ross&age=" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", age: "" })
      end
    end

    context "with overlapping and missing params" do
      let(:q) { "name&name=" }

      it "works correctly" do
        expect(subject).to eq({ name: "" })
      end
    end

    context "with encoded values" do
      let(:q) { "ross=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ ross: "m@rried 5 time$" })
      end
    end

    context "with array encoded values" do
      let(:q) { "ross[]=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ ross: ["m@rried 5 time$"] })
      end
    end

    context "with hash encoded values" do
      let(:q) { "users[ross]=m%40rried+5+time%24" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: "m@rried 5 time$" } })
      end
    end

    context "with no array values" do
      let(:q) { "names[]" }

      it "works correctly" do
        expect(subject).to eq({ names: [""] })
      end
    end

    context "with blank array values" do
      let(:q) { "names[]=" }

      it "works correctly" do
        expect(subject).to eq({ names: [""] })
      end
    end

    context "with missing array values" do
      let(:q) { "names[]=ross&occupation" }

      it "works correctly" do
        expect(subject).to eq({ names: ["ross"], occupation: nil })
      end
    end

    context "with missing array values" do
      let(:q) { "occupation&names[]=ross" }

      it "works correctly" do
        expect(subject).to eq({ occupation: nil, names: ["ross"] })
      end
    end

    context "with missing array specifiers" do
      let(:q) { "names[]=ross&names[=chandler" }

      it "raises an error" do
        expect { subject }.to raise_error("Bad params")
      end
    end

    context "with missing array specifiers and blank values" do
      let(:q) { "names[]=ross&names[=" }

      it "raises an error" do
        expect { subject }.to raise_error("Bad params")
      end
    end

    context "with mixed plain and array params" do
      let(:q) { "name=ross&friends[]=1&friends[]=2&friends[]=3" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", friends: %w(1 2 3) })
      end
    end

    context "with nested hashes and missing values" do
      let(:q) { "user[ross][occupation]" }

      it "works correctly" do
        expect(subject).to eq({ user: { ross: { occupation: "" } } })
      end
    end

    context "with nested hashes and blank values" do
      let(:q) { "user[ross][occupation]=" }

      it "works correctly" do
        expect(subject).to eq({ user: { ross: { occupation: "" } } })
      end
    end

    context "with array surrounded by hash" do
      let(:q) { "ross[friends][][id]=1" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1" }] } })
      end
    end

    context "with changing types" do
      let(:q) { "users[ross][][friends][]=10" }

      it "works correctly" do
        expect(subject).to eq({ users: { ross: [{ friends: ["10"] }] } })
      end
    end

    context "with multiple arrays surrounded by hash" do
      let(:q) { "ross[friends][][id]=1&ross[friends][][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1", name: "chandler" }] } })
      end
    end

    context "mixed arrays and hashes" do
      let(:q) { "ross[wives][][third][id]=123" }

      it "works correctly" do
        expect(subject).to eq({ ross: { wives: [{ third: { id: "123" } }] } })
      end
    end

    context "plain keys inside [] and nested hashes" do
      let(:q) { "[ross][][friends]=1&ross[friends][][data][id]=2" }

      it "works correctly" do
        expect(subject).to eq({ "[ross]": [{ friends: "1" }], ross: { friends: [{ data: { id: "2" } }] } })
      end
    end

    context "plain keys inside [] and nested hashes" do
      let(:q) { "[ross][][friends]=1&ross[friends][][data][id]=2" }

      it "works correctly" do
        expect(subject).to eq({ "[ross]": [{ friends: "1" }], ross: { friends: [{ data: { id: "2" } }] } })
      end
    end

    context "with multiple arrays surrounded by hashes with same keys" do
      let(:q) { "ross[friends][][id]=1&ross[friends][][id]=222" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: [{ id: "1" }, { id: "222" }] } })
      end
    end

    context "with nested hashes with repeated keys" do
      let(:q) { "friends[data][][friends][name]=ross&friends[data][][friends][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: { data: [{ friends: { name: "ross" } }, { friends: { name: "joey" } }] } })
      end
    end

    context "with nested hashes with rotating keys" do
      let(:q) { "friends[data][][id]=1&friends[data][][name]=ross&friends[data][][id]=22&friends[data][][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: { data: [{ id: "1", name: "ross" }, { id: "22", name: "joey" }] } })
      end
    end

    context "with nested hashes with rotating keys inside array" do
      let(:q) { "friends[][id]=1&friends[][dob][year]=1967&friends[][id]=2&friends[][dob][year]=1968" }

      it "works correctly" do
        expect(subject).to eq({ friends: [{ id: "1", dob: { year: "1967" } }, { id: "2", dob: { year: "1968" } }] })
      end
    end

    context "with nested hashes with rotating keys inside array" do
      let(:q) { "friends[][id]=1&friends[][name]=ross&friends[][idd]=2&friends[][name]=joey" }

      it "works correctly" do
        expect(subject).to eq({ friends: [{ id: "1", name: "ross", idd: "2" }, { name: "joey" }] })
      end
    end

    context "with deep nested hashes with rotating keys" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][name]=ross&users[][data][attrs][id]=22&users[][data][attrs][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11", name: "ross" } } }, { data: { attrs: { id: "22", name: "chandler" } } }] })
      end
    end

    context "with deep nested hashes with rotating keys in different order" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][name]=ross&users[][data][attributes][id]=22&users[][data][attributes][id]=33&users[][data][attrs][id]=22&users[][data][attrs][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11", name: "ross" }, attributes: { id: "22" } } }, { data: { attributes: { id: "33" }, attrs: { id: "22", name: "chandler" } } }] })
      end
    end

    context "with nested hashes inside an array" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][id]=22" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { attrs: { id: "11" } } }, { data: { attrs: { id: "22" } } }] })
      end
    end

    context "with different keys inside nested structures" do
      let(:q) { "users[][data][id1]=1&users[][data][id2]=3" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id1: "1", id2: "3" } }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][id]=1&x[][y][a]=5&x[][y][b]=7&x[][z][id]=3&x[][z][w]=0&x[][id]=2&x[][y][a]=6&x[][y][b]=8&x[][z][id]=4&x[][z][w]=0" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ id: "1", y: { a: "5", b: "7" }, z: { id: "3", w: "0" } }, { id: "2", y: { a: "6", b: "8" }, z: { id: "4", w: "0" } }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][z][w]=a&x[][y]=1&x[][z][w]=b&x[][y]=2" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ z: { w: "a" }, y: "1" }, { z: { w: "b" }, y: "2" }] })
      end
    end

    context "with mixed data structures" do
      let(:q) { "x[][y]=1&x[][z][w]=a&x[][y]=2&x[][z][w]=b" }

      it "works correctly" do
        expect(subject).to eq({ x: [{ z: { w: "a" }, y: "1" }, { z: { w: "b" }, y: "2" }] })
      end
    end

    context "with deep params" do
      let(:q) { "friends[][][data][][id][]=1" }

      it "raises an error" do
        expect { subject }.to raise_error("Params too deep")
      end
    end

    context "with incorrect params" do
      let(:q) { "a[]=1&a[b]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a[b]=1&a[]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a=1&a[]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "a=1&a[b]=2" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[][]=ross&users[][name]=chandler" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[friends][name]=monica" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "ross[friends][]=chandler&ross[friends][]=joey&ross[]=monica" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][attrs][name]=joey" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[user][id]=11&users[user][name]=ross&users[user][friends][][id]=22&users[user][friends][][name]=chandler&users[user][friends][][id]=33&users[user][friends][name]=joey" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end

    context "with incorrect params" do
      let(:q) { "users[][data][attrs][id]=11&users[][data][attrs][id][name]=ross" }

      it "raises an error" do
        expect { subject }.to raise_error(TypeError)
      end
    end
  end

  describe "#parse_urlencoded_nested_query" do
    subject { described_class.parse_urlencoded_nested_query(q) }

    context "with unencoded plain params" do
      let(:q) { "name=ross&occupation=paleontologist" }

      it "works correctly" do
        expect(subject).to eq({ name: "ross", occupation: "paleontologist" })
      end
    end

    context "with a query encoded as a single component" do
      let(:q) { "name%3Dross%26occupation%3Dpaleontologist" }

      it "treats the query as one key" do
        expect(subject).to eq({ "name=ross&occupation=paleontologist": nil })
      end
    end

    context "unencoded complex params" do
      let(:q) { "users[][data][id]=11&users[][data][name]=ross&users[][data][id]=22&users[][data][name]=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end

    context "encoded complex params" do
      let(:q) { "users%5B%5D%5Bdata%5D%5Bid%5D=11&users%5B%5D%5Bdata%5D%5Bname%5D=ross&users%5B%5D%5Bdata%5D%5Bid%5D=22&users%5B%5D%5Bdata%5D%5Bname%5D=chandler" }

      it "works correctly" do
        expect(subject).to eq({ users: [{ data: { id: "11", name: "ross" } }, { data: { id: "22", name: "chandler" } }] })
      end
    end

    context "encoded ampersands" do
      let(:q) { "ross%5Bfriends%5D=chandler+%26+chandlers+mom" }

      it "works correctly" do
        expect(subject).to eq({ ross: { friends: "chandler & chandlers mom" } })
      end
    end

    context "with encoded keys" do
      let(:q) { "first+name=ross&users%5B%5D%5Bname%5D=chandler" }

      it "decodes spaces and nesting in keys" do
        expect(subject).to eq({ "first name": "ross", users: [{ name: "chandler" }] })
      end
    end

    context "with encoded values" do
      let(:q) { "value=a%2Bb+%2526+%25+%26+%3D" }

      it "decodes each component exactly once" do
        expect(subject).to eq({ value: "a+b %26 % & =" })
      end
    end

    context "with a mutable input string" do
      let(:q) { "name=ross%26chandler".dup }

      it "does not modify the input" do
        expect { subject }.not_to change { q.dup }
      end
    end

    context "with valueless nested params followed by another param" do
      let(:q) { "names[]&users[name]&active" }

      it "keeps each parameter separate" do
        expect(subject).to eq({ names: [""], users: { name: "" }, active: nil })
      end
    end

    context "with encoded nested keys" do
      let(:q) { "users[][data][id]=11&users[][data][first%26name]=ross&users[][data][last%3Dname]=geller" }

      it "groups distinct keys in the same array element" do
        expect(subject).to eq({ users: [
          { data: { id: "11", "first&name".to_sym => "ross", "last=name".to_sym => "geller" } }
        ]})
      end

      context "when encoded key repeats" do
        let(:q) { "#{super()}&users[][data][id]=22&users[][data][first%26name]=chandler&users[][data][last%3Dname]=bing" }

        it "starts a new array element" do
          expect(subject).to eq({ users: [
            { data: { id: "11", "first&name".to_sym => "ross", "last=name".to_sym => "geller" } },
            { data: { id: "22", "first&name".to_sym => "chandler", "last=name".to_sym => "bing" } }
          ]})
        end
      end
    end

    context "with malformed encoding in a key" do
      let(:q) { "name%GG=ross" }

      it "raises a decoding error" do
        expect { subject }.to raise_error(RuntimeError, /Malformed URL string/)
      end
    end

    context "with malformed encoding in a value" do
      let(:q) { "name=ross%2" }

      it "raises a decoding error" do
        expect { subject }.to raise_error(RuntimeError, /Malformed URL string/)
      end
    end
  end

  describe "#parse_multipart", with_app: :params do
    subject { described_class.parse_multipart(q) }

    context "with a file" do
      let(:file) do
        Tempfile.new.tap do |f|
          f.write "hello\nworld\0\xF0\x9F\x98\x80"
          f.rewind
        end
      end

      it "works correctly" do
        response = http_post("/", form: {
          message: HTTP::FormData::File.new(file.path)
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["message_digest"]).to eq("9f18eb0338a94b5306cf6ab104ada8c8")
      end
    end

    context "with params" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        response = http_post("/", form: {
          count: 1,
          avatar: HTTP::FormData::File.new(file.path),
          "users[user][id]" => 11,
          "users[user][name]" => "ross",
          "users[user][friends][][id]" => 22,
          "users[user][friends][][name]" => "chandler"
        })

        expect(response.status.to_i).to eq(200)
        parsed = response.parse
        expect(parsed["users"]).to eq({ "user" => { "id" => "11", "name" => "ross", "friends" => [{ "id" => "22", "name" => "chandler" }] } })
        expect(parsed["count"]).to eq("1")
        expect(parsed["avatar_digest"]).to eq("d41d8cd98f00b204e9800998ecf8427e")
      end
    end

    context "with malformed params" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        response = http_post("/", form: {
          "file" => HTTP::FormData::File.new(file.path),
          "param[" => "test"
        })

        expect(response.status.to_i).to eq(500)
        expect(response.body.to_s).to eq("Bad params")
      end
    end

    context "with malformed body" do
      it "works correctly" do
        response = http_post("/", form: { "param[" => "test" })

        expect(response.status.to_i).to eq(500)
        expect(response.body.to_s).to eq("Malformed multipart request")
      end
    end

    context "with a file bigger than one block" do
      let(:file) do
        Tempfile.new.tap do |f|
          f.write "1" * 300_000
          f.rewind
        end
      end

      it "works correctly" do
        response = http_post("/", form: {
          f: HTTP::FormData::File.new(file.path)
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["f_digest"]).to eq("4bc18f32f2f14a84890b5680ffeb2cbb")
      end
    end

    context "with a parameter bigger than one block" do
      let(:file) { Tempfile.new }

      it "works correctly" do
        string = rand(10).to_s * 300_000

        response = http_post("/", form: {
          file: HTTP::FormData::File.new(file.path),
          parameter: string
        })

        expect(response.status.to_i).to eq(200)
        expect(response.parse["parameter"]).to eq(string)
      end
    end

    context "with delimiters in nested multipart keys" do
      let(:file) { Tempfile.new }

      context "with &" do
        it "groups distinct keys in the same array element" do
          response = http_post("/", form: {
            file: HTTP::FormData::File.new(file.path),
            "users[][data][id]" => "11",
            "users[][data][first&name]" => "ross",
            "users[][data][last&name]" => "geller"
          })

          expect(response.status.to_i).to eq(200)
          expect(response.parse["users"]).to eq([
            { "data" => { "id" => "11", "first&name" => "ross", "last&name" => "geller" } }
          ])
        end
      end

      context "with =" do
        it "groups distinct keys in the same array element" do
          response = http_post("/", form: {
            file: HTTP::FormData::File.new(file.path),
            "users[][data][id]" => "11",
            "users[][data][first=name]" => "ross",
            "users[][data][last=name]" => "geller"
          })

          expect(response.status.to_i).to eq(200)
          expect(response.parse["users"]).to eq([
            { "data" => { "id" => "11", "first=name" => "ross", "last=name" => "geller" } }
          ])
        end
      end
    end
  end
end
