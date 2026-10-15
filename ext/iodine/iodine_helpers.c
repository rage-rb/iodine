/*
Copyright: Boaz segev, 2016-2017
License: MIT

Feel free to copy, use and enjoy according to the license provided.
*/
#include "iodine.h"

#include "http.h"
#include <ruby/encoding.h>

/*
Add all sorts of useless stuff here.
*/

static ID iodine_to_i_func_id;
static rb_encoding *IodineUTF8Encoding;

/* *****************************************************************************
URL Decoding
***************************************************************************** */
/**
Decodes a URL encoded String in place.

Raises an exception on error... but this might result in a partially decoded
String.
*/
static VALUE url_decode_inplace(VALUE self, VALUE str) {
  Check_Type(str, T_STRING);
  ssize_t len =
      http_decode_url(RSTRING_PTR(str), RSTRING_PTR(str), RSTRING_LEN(str));
  if (len < 0)
    rb_raise(rb_eRuntimeError, "Malformed URL string - couldn't decode (String "
                               "might have been partially altered).");
  rb_str_set_len(str, len);
  return str;
  (void)self;
}

/**
Decodes a URL encoded String, returning a new String with the decoded data.
*/
static VALUE url_decode(VALUE self, VALUE str) {
  Check_Type(str, T_STRING);
  VALUE str2 = rb_str_buf_new(RSTRING_LEN(str));
  ssize_t len =
      http_decode_url(RSTRING_PTR(str2), RSTRING_PTR(str), RSTRING_LEN(str));
  if (len < 0)
    rb_raise(rb_eRuntimeError, "Malformed URL string - couldn't decode.");
  rb_str_set_len(str2, len);
  return str2;
  (void)self;
}

/**
Decodes a percent encoded String (normally the "path" of a request), editing the
String in place.

Raises an exception on error... but this might result in a partially decoded
String.
*/
static VALUE path_decode_inplace(VALUE self, VALUE str) {
  Check_Type(str, T_STRING);
  ssize_t len =
      http_decode_path(RSTRING_PTR(str), RSTRING_PTR(str), RSTRING_LEN(str));
  if (len < 0)
    rb_raise(rb_eRuntimeError,
             "Malformed URL path string - couldn't decode (String "
             "might have been partially altered).");
  rb_str_set_len(str, len);
  return str;
  (void)self;
}

/**
Decodes a percent encoded String (normally the "path" of a request), returning a
new String with the decoded data.
*/
static VALUE path_decode(VALUE self, VALUE str) {
  Check_Type(str, T_STRING);
  VALUE str2 = rb_str_buf_new(RSTRING_LEN(str));
  ssize_t len =
      http_decode_path(RSTRING_PTR(str2), RSTRING_PTR(str), RSTRING_LEN(str));
  if (len < 0)
    rb_raise(rb_eRuntimeError, "Malformed URL path string - couldn't decode.");
  rb_str_set_len(str2, len);
  return str2;
  (void)self;
}

/**
Decodes a URL encoded String, returning a new String with the decoded data.

This variation matches the Rack::Utils.unescape signature by accepting and
mostly ignoring an optional Encoding argument.
*/
static VALUE unescape(int argc, VALUE *argv, VALUE self) {
  if (argc < 1 || argc > 2)
    rb_raise(rb_eArgError,
             "wrong number of arguments (given %d, expected 1..2).", argc);
  VALUE str = argv[0];
  Check_Type(str, T_STRING);
  VALUE str2 = rb_str_buf_new(RSTRING_LEN(str));
  ssize_t len =
      http_decode_url(RSTRING_PTR(str2), RSTRING_PTR(str), RSTRING_LEN(str));
  if (len < 0)
    rb_raise(rb_eRuntimeError, "Malformed URL path string - couldn't decode.");
  rb_str_set_len(str2, len);
  rb_encoding *enc = IodineUTF8Encoding;
  if (argc == 2 && argv[1] != Qnil && argv[1] != Qfalse) {
    enc = rb_enc_get(argv[1]);
    if (!enc)
      enc = IodineUTF8Encoding;
  }
  rb_enc_associate(str2, enc);
  return str2;
  (void)self;
}

/* *****************************************************************************
HTTP Dates
***************************************************************************** */

/**
Takes an optional Integer for Unix Time and returns a faster (though less
localized) HTTP Date formatted String.


        Iodine::Rack.time2str => "Sun, 11 Jun 2017 06:14:08 GMT"

        Iodine::Rack.time2str(Time.now.to_i) => "Wed, 15 Nov 1995 06:25:24 GMT"

Since Iodine uses time caching within it's reactor, using the default value
(now) will be faster than providing an explicit time using `Time.now.to_i`.

*/
static VALUE date_str(int argc, VALUE *argv, VALUE self) {
  if (argc > 1)
    rb_raise(rb_eArgError,
             "wrong number of arguments (given %d, expected 0..1).", argc);
  time_t last_tick;
  if (argc) {
    if (TYPE(argv[0]) != T_FIXNUM)
      argv[0] = rb_funcallv(argv[0], iodine_to_i_func_id, 0, NULL);
    Check_Type(argv[0], T_FIXNUM);
    last_tick =
        FIX2ULONG(argv[0]) ? FIX2ULONG(argv[0]) : fio_last_tick().tv_sec;
  } else
    last_tick = fio_last_tick().tv_sec;
  VALUE str = rb_str_buf_new(32);
  struct tm tm;

  http_gmtime(last_tick, &tm);
  size_t len = http_date2str(RSTRING_PTR(str), &tm);
  rb_str_set_len(str, len);
  return str;
  (void)self;
}

/**
Takes `time` and returns a faster (though less localized) HTTP Date formatted
String.


        Iodine::Rack.rfc2822(Time.now) => "Sun, 11 Jun 2017 06:14:08 -0000"

        Iodine::Rack.rfc2822(0)      => "Sun, 11 Jun 2017 06:14:08 -0000"

Since Iodine uses time caching within it's reactor, using the default value
(by passing 0) will be faster than providing an explicit time using `Time.now`.
*/
static VALUE iodine_rfc2822(VALUE self, VALUE rtm) {
  time_t last_tick;
  rtm = rb_funcallv(rtm, iodine_to_i_func_id, 0, NULL);
  last_tick = FIX2ULONG(rtm) ? FIX2ULONG(rtm) : fio_last_tick().tv_sec;
  VALUE str = rb_str_buf_new(34);
  struct tm tm;

  http_gmtime(last_tick, &tm);
  size_t len = http_date2rfc2822(RSTRING_PTR(str), &tm);
  rb_str_set_len(str, len);
  return str;
  (void)self;
}

/**
Takes `time` and returns a faster (though less localized) HTTP Date formatted
String.


        Iodine::Rack.rfc2109(Time.now) => "Sun, 11-Jun-2017 06:14:08 GMT"

        Iodine::Rack.rfc2109(0)      => "Sun, 11-Jun-2017 06:14:08 GMT"

Since Iodine uses time caching within it's reactor, using the default value
(by passing 0) will be faster than providing an explicit time using `Time.now`.
*/
static VALUE iodine_rfc2109(VALUE self, VALUE rtm) {
  time_t last_tick;
  rtm = rb_funcallv(rtm, iodine_to_i_func_id, 0, NULL);
  last_tick = FIX2ULONG(rtm) ? FIX2ULONG(rtm) : fio_last_tick().tv_sec;
  VALUE str = rb_str_buf_new(32);
  struct tm tm;

  http_gmtime(last_tick, &tm);
  size_t len = http_date2rfc2109(RSTRING_PTR(str), &tm);
  rb_str_set_len(str, len);
  return str;
  (void)self;
}

/**
Convert query string into a Ruby object without recursion.


        Iodine::Rack::Utils.parse_nested_query("a=1&b[]=2&c[d]=3") # => { "a" => "1", "b" => ["2"], "c" => { "d" => "3" } }



        query = "a=1&b[]=2&c[d]=3"
        Benchmark.ips do |x|
          x.report("Iodine") {
            Iodine::Rack::Utils.parse_nested_query(query)
          }

          x.report("Rack") {
            Rack::Utils.parse_nested_query(query)
          }

          x.compare!
        end


        Calculating -------------------------------------
              Iodine      1.088M (~ 1.1%) i/s -      5.526M in   5.077759s
                Rack     64.258k (~ 1.0%) i/s -    321.657k in   5.006187s

        Comparison:
                      Iodine:  1088431.2 i/s
                        Rack:    64257.9 i/s - 16.94x  slower

*/
static VALUE build_query_component(char *str, size_t len,
                                    uint8_t should_decode) {
  VALUE result = rb_enc_str_new(str, len, IodineUTF8Encoding);
  if (should_decode) {
    url_decode_inplace(Qnil, result);
  }
  return result;
}

static VALUE parse_nested_query_internal(char *str, size_t len) {
  VALUE params = rb_hash_new();
  char *pos = str;
  char *end = str + len;

  while (pos < end) {
    char *pair_end = pos;
    char *separator = NULL;
    uint8_t key_should_decode = 0;
    uint8_t value_should_decode = 0;

    while (pair_end < end && *pair_end != '&') {
      if (!separator && *pair_end == '=') {
        separator = pair_end;
      } else if (*pair_end == '%' || *pair_end == '+') {
        if (separator) {
          value_should_decode = 1;
        } else {
          key_should_decode = 1;
        }
      }
      pair_end++;
    }

    char *key_end = separator ? separator : pair_end;
    VALUE key = Qnil;
    char *key_data = pos;
    size_t key_len = key_end - pos;

    if (key_should_decode) {
      key = build_query_component(pos, key_len, 1);
      key_data = RSTRING_PTR(key);
      key_len = RSTRING_LEN(key);
    }

    VALUE value;
    if (separator) {
      value = build_query_component(separator + 1,
                                     pair_end - separator - 1,
                                     value_should_decode);
    } else if (key_len > 1 && memchr(key_data + 1, '[', key_len - 1)) {
      value = rb_enc_str_new(NULL, 0, IodineUTF8Encoding);
    } else {
      value = Qnil;
    }

    http_add_to_params(params, key_data, key_len, value);
    RB_GC_GUARD(key);

    if (pair_end == end) {
      break;
    }
    pos = pair_end + 1;
  }

  return params;
}

/**
Convert query string into a Ruby object.
*/
static VALUE parse_nested_query(VALUE self, VALUE r_str) {
  (void)self;
  Check_Type(r_str, T_STRING);
  VALUE result =
      parse_nested_query_internal(RSTRING_PTR(r_str), RSTRING_LEN(r_str));
  RB_GC_GUARD(r_str);
  return result;
}

/**
Convert urlencoded body into a Ruby object.
*/
static VALUE parse_urlencoded_nested_query(VALUE self, VALUE r_str) {
  (void)self;
  Check_Type(r_str, T_STRING);
  char *str = RSTRING_PTR(r_str);
  size_t len = RSTRING_LEN(r_str);

  VALUE result = parse_nested_query_internal(str, len);
  RB_GC_GUARD(r_str);
  return result;
}

/**
Convert multipart/form-data into a Ruby object.
*/
static VALUE parse_multipart(VALUE self, VALUE rack_io, VALUE content_type) {
  http_s *h = IodineRackIO.get_handle(rack_io);

  if (content_type == Qnil) {
    rb_raise(rb_eRuntimeError, "Incorrect content type for multipart request");
  }

  return http_parse_multipart(h, RSTRING_PTR(content_type), RSTRING_LEN(content_type));
  (void)self;
}

/**
Generate a timestamp to use in logs.
*/
static VALUE gen_timestamp(VALUE self) {
  struct tm tm;
  time_t last_tick = fio_last_tick().tv_sec;
  http_gmtime(last_tick, &tm);

  char buffer[32];
  size_t len = http_date2timestamp(buffer, &tm);

  return rb_str_new(buffer, len);
}

static const char request_tag_seed[] = "abcdefghijklmnopqrstuvwxyz0123456789";
static const uint8_t request_tag_len = 16;

/**
Generate a request tag to use in logs.
*/
static VALUE gen_request_tag(VALUE self) {
  char buffer[request_tag_len];
  uint8_t i, random_index;

  for (i = 0; i < request_tag_len; i++) {
    random_index = rand() % 36;
    buffer[i] = request_tag_seed[random_index];
  }

  return rb_str_new(buffer, request_tag_len);
}

/* *****************************************************************************
Ruby Initialization
***************************************************************************** */

void iodine_init_helpers(void) {
  iodine_to_i_func_id = rb_intern("to_i");
  IodineUTF8Encoding = rb_enc_find("UTF-8");
  VALUE tmp = rb_define_module_under(IodineModule, "Rack");
  // clang-format off
  /*
Iodine does NOT monkey patch Rack automatically. However, it's possible and recommended to moneky patch Rack::Utils to use the methods in this module.

Choosing to monkey patch Rack::Utils could offer significant performance gains for some applications. i.e. (on my machine):

      require 'iodine'
      require 'rack'
      # a String in need of decoding
      s = '%E3%83%AB%E3%83%93%E3%82%A4%E3%82%B9%E3%81%A8'
      Benchmark.bm do |bm|
        # Pre-Patch
        bm.report("   Rack.unescape")    {1_000_000.times { Rack::Utils.unescape s } }
        bm.report("    Rack.rfc2822")    {1_000_000.times { Rack::Utils.rfc2822(Time.now) } }
        bm.report("    Rack.rfc2109")    {1_000_000.times { Rack::Utils.rfc2109(Time.now) } }
        # Perform Patch
        Iodine.patch_rack
        puts "            --- Monkey Patching Rack ---"
        # Post Patch
        bm.report("Patched.unescape")    {1_000_000.times { Rack::Utils.unescape s } }
        bm.report(" Patched.rfc2822")    {1_000_000.times { Rack::Utils.rfc2822(Time.now) } }
        bm.report(" Patched.rfc2109")    {1_000_000.times { Rack::Utils.rfc2109(Time.now) } }
      end && nil

Results:
        user     system      total        real
        Rack.unescape  8.706881   0.019995   8.726876 (  8.740530)
        Rack.rfc2822  3.270305   0.007519   3.277824 (  3.279416)
        Rack.rfc2109  3.152188   0.003852   3.156040 (  3.157975)
                   --- Monkey Patching Rack ---
        Patched.unescape  0.327231   0.003125   0.330356 (  0.337090)
        Patched.rfc2822  0.691304   0.003330   0.694634 (  0.701172)
        Patched.rfc2109  0.685029   0.001956   0.686985 (  0.687607)

  */
  tmp = rb_define_module_under(tmp, "Utils");
  // clang-format on
  rb_define_module_function(tmp, "decode_url!", url_decode_inplace, 1);
  rb_define_module_function(tmp, "decode_url", url_decode, 1);
  rb_define_module_function(tmp, "decode_path!", path_decode_inplace, 1);
  rb_define_module_function(tmp, "decode_path", path_decode, 1);
  rb_define_module_function(tmp, "time2str", date_str, -1);
  rb_define_module_function(tmp, "rfc2109", iodine_rfc2109, 1);
  rb_define_module_function(tmp, "rfc2822", iodine_rfc2822, 1);
  rb_define_module_function(tmp, "parse_nested_query", parse_nested_query, 1);
  rb_define_module_function(tmp, "parse_urlencoded_nested_query", parse_urlencoded_nested_query, 1);
  rb_define_module_function(tmp, "parse_multipart", parse_multipart, 2);
  rb_define_module_function(tmp, "gen_timestamp", gen_timestamp, 0);
  rb_define_module_function(tmp, "gen_request_tag", gen_request_tag, 0);

  /*
The monkey-patched methods are in this module, allowing Iodine::Rack::Utils to
include non-patched methods as well.
  */
  tmp = rb_define_module_under(IodineBaseModule, "MonkeyPatch");
  tmp = rb_define_module_under(tmp, "RackUtils");
  // clang-format on
  /* we define it all twice for easier monkey patching */
  rb_define_method(tmp, "unescape", unescape, -1);
  rb_define_method(tmp, "unescape_path", path_decode, 1);
  rb_define_method(tmp, "rfc2109", iodine_rfc2109, 1);
  rb_define_method(tmp, "rfc2822", iodine_rfc2822, 1);
  rb_define_singleton_method(tmp, "unescape", unescape, -1);
  rb_define_singleton_method(tmp, "unescape_path", path_decode, 1);
  rb_define_singleton_method(tmp, "rfc2109", iodine_rfc2109, 1);
  rb_define_singleton_method(tmp, "rfc2822", iodine_rfc2822, 1);
  // rb_define_module_function(IodineUtils, "time2str", date_str, -1);
}
