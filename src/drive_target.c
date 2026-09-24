/* drive_target: dlopen a shared library exporting the lui_ocaml_* bridge
   ABI (the same ABI the SwiftUI host uses) and drive it headlessly.
   The patch callback is pure C — patch JSON strings are queued and later
   popped by OCaml via drive_target_next, so no OCaml code ever runs on
   the embedded runtime's threads. */

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/custom.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*patch_cb)(const char *);

typedef struct {
  void *lib;
  int32_t (*start)(patch_cb, int32_t, int32_t);
  int32_t (*appear)(int64_t);
  int32_t (*press)(int64_t);
  int32_t (*long_press)(int64_t);
  int32_t (*submit)(int64_t);
  int32_t (*dismiss)(int64_t);
  int32_t (*double_press)(int64_t);
  int32_t (*radio_changed)(int64_t);
  int32_t (*text_changed)(int64_t, const char *);
  int32_t (*toggle_changed)(int64_t, int32_t);
  int32_t (*slider_changed)(int64_t, double);
  int32_t (*extension)(int64_t, const char *, const char *, const char *);
  int32_t (*poll)(void);
  int32_t (*stop)(void);
  int64_t (*root_node)(void);
  /* patch queue: producer = patch_sink on the embedded runtime's
     dispatcher thread; consumer = OCaml via drive_target_next. */
  pthread_mutex_t q_lock;
  char **queue;
  int head, tail, cap;
} drive_target;

static void sink_push(drive_target *t, const char *json) {
  pthread_mutex_lock(&t->q_lock);
  int next = (t->tail + 1) % t->cap;
  if (next != t->head) { /* drop if full: keep latest semantics? keep all, grow instead */
    t->queue[t->tail] = strdup(json);
    t->tail = next;
  } else {
    /* grow */
    int ncap = t->cap * 2;
    char **nq = calloc(ncap, sizeof(char *));
    int i = 0;
    for (int j = t->head; j != t->tail; j = (j + 1) % t->cap) {
      nq[i++] = t->queue[j];
    }
    free(t->queue);
    t->queue = nq;
    t->head = 0;
    t->tail = i;
    t->cap = ncap;
    t->queue[t->tail] = strdup(json);
    t->tail = (t->tail + 1) % t->cap;
  }
  pthread_mutex_unlock(&t->q_lock);
}

static drive_target *current = NULL;

static void patch_sink(const char *json) {
  if (current == NULL || json == NULL) return;
  sink_push(current, json);
}

static char *q_pop(drive_target *t) {
  pthread_mutex_lock(&t->q_lock);
  char *r = NULL;
  if (t->head != t->tail) {
    r = t->queue[t->head];
    t->head = (t->head + 1) % t->cap;
  }
  pthread_mutex_unlock(&t->q_lock);
  return r;
}

static void *sym(void *lib, const char *name) {
  void *p = dlsym(lib, name);
  if (p == NULL) fprintf(stderr, "drive: missing symbol %s\n", name);
  return p;
}

#define Target_val(v) (*(drive_target **)Data_custom_val(v))

static void target_finalize(value v) {
  drive_target *t = Target_val(v);
  if (t->lib) dlclose(t->lib);
  pthread_mutex_destroy(&t->q_lock);
  for (int j = t->head; j != t->tail; j = (j + 1) % t->cap) free(t->queue[j]);
  free(t->queue);
  free(t);
}

static struct custom_operations target_ops = {
  "drive.target", target_finalize, custom_compare_default,
  custom_hash_default, custom_serialize_default,
  custom_deserialize_default, custom_compare_ext_default,
  custom_fixed_length_default};

CAMLprim value drive_target_open(value pathv) {
  CAMLparam1(pathv);
  CAMLlocal1(res);
  const char *path = String_val(pathv);
  /* The target .so bundles its own OCaml runtime (ocamlopt
     -output-complete-obj). RTLD_DEEPBIND makes it resolve its own
     caml_* symbols before the host executable's, so two runtimes can
     coexist in one process. */
#ifdef __APPLE__
  /* macOS has no RTLD_DEEPBIND; RTLD_LOCAL still keeps the bundled
     runtime's caml_* symbols out of the host's global namespace. */
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
#else
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
#endif
  if (lib == NULL) caml_failwith(dlerror());
  drive_target *t = calloc(1, sizeof(drive_target));
  t->lib = lib;
  t->cap = 64;
  t->queue = calloc(t->cap, sizeof(char *));
  pthread_mutex_init(&t->q_lock, NULL);
  t->start = sym(lib, "lui_ocaml_start");
  t->appear = sym(lib, "lui_ocaml_appear");
  t->press = sym(lib, "lui_ocaml_press");
  t->long_press = sym(lib, "lui_ocaml_long_press");
  t->submit = sym(lib, "lui_ocaml_submit");
  t->dismiss = sym(lib, "lui_ocaml_dismiss");
  t->double_press = sym(lib, "lui_ocaml_double_press");
  t->radio_changed = sym(lib, "lui_ocaml_radio_changed");
  t->text_changed = sym(lib, "lui_ocaml_text_changed");
  t->toggle_changed = sym(lib, "lui_ocaml_toggle_changed");
  t->slider_changed = sym(lib, "lui_ocaml_slider_changed");
  t->extension = sym(lib, "lui_ocaml_extension");
  t->poll = sym(lib, "lui_ocaml_poll");
  t->stop = sym(lib, "lui_ocaml_stop");
  t->root_node = sym(lib, "lui_ocaml_root_node");
  if (t->start == NULL) caml_failwith("drive: library exports no lui_ocaml_start");
  res = caml_alloc_custom(&target_ops, sizeof(drive_target *), 0, 1);
  Target_val(res) = t;
  CAMLreturn(res);
}

CAMLprim value drive_target_start(value tv, value osv, value hostv) {
  CAMLparam3(tv, osv, hostv);
  drive_target *t = Target_val(tv);
  current = t;
  int ok = t->start(patch_sink, (int32_t)Int_val(osv), (int32_t)Int_val(hostv));
  CAMLreturn(Val_int(ok));
}

/* event dispatch: name selects the exported call. Returns 0/1. */
CAMLprim value drive_target_event(value tv, value namev, value nodev,
                                  value a, value b, value c, value iv,
                                  value fv) {
  CAMLparam5(tv, namev, nodev, a, b);
  CAMLxparam3(c, iv, fv);
  drive_target *t = Target_val(tv);
  const char *name = String_val(namev);
  int64_t node = Int64_val(nodev);
  int ok = 0;
  if (!strcmp(name, "appear") && t->appear) ok = t->appear(node);
  else if (!strcmp(name, "press") && t->press) ok = t->press(node);
  else if (!strcmp(name, "long_press") && t->long_press) ok = t->long_press(node);
  else if (!strcmp(name, "submit") && t->submit) ok = t->submit(node);
  else if (!strcmp(name, "dismiss") && t->dismiss) ok = t->dismiss(node);
  else if (!strcmp(name, "double_press") && t->double_press) ok = t->double_press(node);
  else if (!strcmp(name, "radio_changed") && t->radio_changed) ok = t->radio_changed(node);
  else if (!strcmp(name, "text_changed") && t->text_changed)
    ok = t->text_changed(node, String_val(a));
  else if (!strcmp(name, "toggle_changed") && t->toggle_changed)
    ok = t->toggle_changed(node, Int_val(iv));
  else if (!strcmp(name, "slider_changed") && t->slider_changed)
    ok = t->slider_changed(node, Double_val(fv));
  else if (!strcmp(name, "extension") && t->extension)
    ok = t->extension(node, String_val(a), String_val(b), String_val(c));
  CAMLreturn(Val_int(ok));
}

CAMLprim value drive_target_event_bc(value *argv, int argn) {
  (void)argn;
  return drive_target_event(argv[0], argv[1], argv[2], argv[3], argv[4],
                            argv[5], argv[6], argv[7]);
}

CAMLprim value drive_target_poll(value tv) {
  CAMLparam1(tv);
  drive_target *t = Target_val(tv);
  int ok = t->poll ? t->poll() : 1;
  CAMLreturn(Val_int(ok));
}

CAMLprim value drive_target_next(value tv) {
  CAMLparam1(tv);
  CAMLlocal2(res, s);
  drive_target *t = Target_val(tv);
  char *json = q_pop(t);
  if (json == NULL) CAMLreturn(Val_int(0)); /* None */
  s = caml_copy_string(json);
  free(json);
  res = caml_alloc_small(1, 0);
  Field(res, 0) = s;
  CAMLreturn(res); /* Some json */
}

CAMLprim value drive_target_stop(value tv) {
  CAMLparam1(tv);
  drive_target *t = Target_val(tv);
  int ok = t->stop ? t->stop() : 1;
  CAMLreturn(Val_int(ok));
}

CAMLprim value drive_target_root(value tv) {
  CAMLparam1(tv);
  drive_target *t = Target_val(tv);
  int64_t n = t->root_node ? t->root_node() : -1;
  CAMLreturn(caml_copy_int64(n));
}
