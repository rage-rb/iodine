#ifndef H_IODINE_RACK_STREAM_H
#define H_IODINE_RACK_STREAM_H

#include <ruby.h>

#include "http.h"

extern struct IodineRackStream {
  VALUE (*create)(http_s *h, VALUE fiber);
  void (*close)(VALUE stream);
  void (*init)(void);

} IodineRackStream;

#endif /* H_IODINE_RACK_STREAM_H */
