/*
 * PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
 *
 * Live viewer for the ZCU104 GestureFlow pipeline: a small HTTP server that a
 * laptop browser talks to over the board's GbE port, showing the frame the NPU
 * is actually looking at, the classification, and the timing breakdown.
 *
 * ---------------------------------------------------------------------------
 * The one rule: it must not slow the recognition loop down.
 *
 *   1. Nothing is copied unless a client asked for that stream within the last
 *      REQ_TIMEOUT seconds.  With no browser attached the whole module costs a
 *      couple of comparisons per frame, so a `gf_camera -n 2000` benchmark run
 *      measures exactly what it measured before --view existed.
 *   2. All socket work happens on background threads.  The capture thread never
 *      touches a socket, so a stalled client or a saturated link can only drop
 *      viewer frames; it cannot add a millisecond to the pipeline.
 *   3. Rotation is applied to the 96x96 input on the board (because that is what
 *      the model is fed, so it has to be right), but the full-resolution scene
 *      is rotated by the browser with a CSS transform -- zero board cost.
 *
 * The full-resolution scene stream is additionally capped at SCENE_MAX_FPS and
 * is off until the page asks for it, because it is ~900 KB per frame against
 * ~27 KB for the 96x96 preview.
 * ---------------------------------------------------------------------------
 */
#ifndef GF_VIEW_H
#define GF_VIEW_H

#include <stdint.h>

/* Everything about one processed frame that the page displays.
 *
 * There is deliberately no "smoothed" class and no vote count.  The monitor
 * reports the class the model produced for THIS frame; smoothing was removed
 * because it is the monitor's job to show what the model does, not to make it
 * look better.  See the comment in gf_camera.c's frame loop. */
typedef struct {
    long   frame;
    double uptime_s;
    double fps;
    int    cls;            /* this frame's class, 0..17 */
    double ms_total;
    double ms_decode;      /* JPEG/YUYV -> RGB */
    double ms_resize;      /* area-average to 96x96 */
    double ms_npu;         /* gf_npu_run_frame */
} gf_view_frame;

/* Which error counters the page shows. */
enum {
    GF_VIEW_ERR_JPEG = 0,
    GF_VIEW_ERR_NPU,
    GF_VIEW_ERR_NCH
};

/* Start the HTTP server on `port`.  `page_path` may be NULL (then the built-in
 * placeholder page is served).  Returns 0 on success.
 *
 * Failing to start the viewer is never fatal -- the caller should print the
 * reason and carry on with the pipeline. */
int  gf_view_start(int port, const char *page_path);

/* Stop accepting connections and shut the background threads down.  Safe to
 * call when the viewer was never started. */
void gf_view_stop(void);

/* Publish one frame.  Cheap no-op unless somebody is watching that stream.
 *
 *   rgb96    the exact 96x96x3 HWC image handed to the NPU (preview stream)
 *   scene    the region the model saw, at source resolution, or NULL
 *   scene_w / scene_h    its geometry
 *   scene_stride         bytes per row in `scene` -- the region is a window of a
 *                        larger frame, so the rows are NOT contiguous
 *
 * Call this after the NPU run, so `f` carries the final timings. */
void gf_view_publish(const gf_view_frame *f,
                     const uint8_t *rgb96,
                     const uint8_t *scene, int scene_w, int scene_h, int scene_stride);

/* Tell the page what the camera negotiated and how the input is framed, so it
 * can label the views.  `zoom` is the V4L2 zoom_absolute value in use (100 =
 * 1x), `crop` the software centre-crop factor (1 = none). */
void gf_view_set_camera(const char *fmt, int w, int h, int rotate_deg,
                        int zoom, double crop);

/* Bump an error counter (shown on the page). */
void gf_view_count_error(int which);

/* Parse a --rotate argument.  Accepts 0/90/180/270 (also -90/270 style is not
 * accepted on purpose: be explicit).  Returns the angle or -1. */
int gf_view_parse_rotate(const char *s);

#endif /* GF_VIEW_H */
