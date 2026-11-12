/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2025 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#include "../../SDL_internal.h"

/* MooGL implementation of SDL OpenGL support: OpenGL 4.6 on Metal in place
   of Apple's NSOpenGL. Modified from SDL's NSOpenGL version for MooGL. */

#ifdef SDL_VIDEO_OPENGL_CGL
#include "SDL_cocoavideo.h"
#include "SDL_cocoaopengl.h"

#include <dlfcn.h>
#include <unistd.h>

#include "SDL_timer.h"

#import <QuartzCore/QuartzCore.h>

/* From libmoogl. MGLRenderer.h needs Metal's headers, so the few calls used
   here are declared instead. */
typedef struct GLMContextRec_t *GLMContext;
extern GLMContext createGLMContext(unsigned format, unsigned type, unsigned depth_format, unsigned depth_type,
                                   unsigned stencil_format, unsigned stencil_type);
extern GLMContext createGLMContextShared(unsigned format, unsigned type, unsigned depth_format, unsigned depth_type,
                                         unsigned stencil_format, unsigned stencil_type, GLMContext share);
extern void destroyGLMContext(GLMContext ctx);
extern void MGLsetCurrentContext(GLMContext ctx);
extern void MGLswapBuffers(GLMContext ctx);
extern void MGLsetSwapInterval(GLMContext ctx, int interval);
extern void MGLsetContextFlags(GLMContext ctx, unsigned flags);

@interface MGLRenderer : NSObject
- (void)createMGLRendererAndBindToContext:(GLMContext)glm_ctx view:(NSView *)view;
@end

#define MGL_BGRA                        0x80E1
#define MGL_UNSIGNED_INT_8_8_8_8_REV    0x8367
#define MGL_DEPTH_COMPONENT             0x1902
#define MGL_FLOAT                       0x1406
#define MGL_STENCIL_INDEX8              0x8D48
#define MGL_UNSIGNED_BYTE               0x1401
#define MGL_CONTEXT_FLAG_DEBUG_BIT      0x00000002
#define MGL_CONTEXT_FLAG_NO_ERROR_BIT   0x00000008

typedef struct MGLSDLContext
{
    GLMContext ctx;
    void *renderer;         /* MGLRenderer, retained */
    SDL_Window *window;     /* the window whose view it draws into */
    int interval;
    double next_swap;
} MGLSDLContext;

/* MooGL has to have a context current for the GL entry points to land
   anywhere, so this stands in when the app has none */
static GLMContext PlaceholderContext(void)
{
    static GLMContext placeholder = NULL;

    if (placeholder == NULL) {
        placeholder = createGLMContext(0, 0, 0, 0, 0, 0);
    }
    return placeholder;
}

int Cocoa_GL_LoadLibrary(_THIS, const char *path)
{
    Dl_info info;

    /* always the copy of libmoogl SDL is linked against; a second copy would
       have its own current context */
    (void)path;
    if (!dladdr((const void *)createGLMContext, &info) || !info.dli_fname) {
        return SDL_SetError("MooGL: can't find libmoogl");
    }

    _this->gl_config.dll_handle = dlopen(info.dli_fname, RTLD_LAZY | RTLD_LOCAL);
    if (!_this->gl_config.dll_handle) {
        return SDL_SetError("MooGL: %s", dlerror());
    }
    SDL_strlcpy(_this->gl_config.driver_path, info.dli_fname, SDL_arraysize(_this->gl_config.driver_path));
    return 0;
}

void *Cocoa_GL_GetProcAddress(_THIS, const char *proc)
{
    return dlsym(_this->gl_config.dll_handle, proc);
}

void Cocoa_GL_UnloadLibrary(_THIS)
{
    if (_this->gl_config.dll_handle) {
        dlclose(_this->gl_config.dll_handle);
    }
    _this->gl_config.dll_handle = NULL;
}

SDL_GLContext Cocoa_GL_CreateContext(_THIS, SDL_Window * window)
{ @autoreleasepool
{
    SDL_WindowData *data = (__bridge SDL_WindowData *)window->driverdata;
    const int major = _this->gl_config.major_version;
    const int minor = _this->gl_config.minor_version;
    const SDL_bool stencil = _this->gl_config.stencil_size > 0;
    unsigned flags = 0;
    MGLSDLContext *context;

    if (_this->gl_config.profile_mask == SDL_GL_CONTEXT_PROFILE_ES) {
        SDL_SetError("MooGL has no OpenGL ES");
        return NULL;
    }

    /* every request up to 4.6 gets 4.6 */
    if (major > 4 || (major == 4 && minor > 6)) {
        SDL_SetError("OpenGL %d.%d is newer than MooGL's 4.6", major, minor);
        return NULL;
    }

    /* SDL_GL_SHARE_WITH_CURRENT_CONTEXT shares with whatever is current now */
    MGLSDLContext *share = _this->gl_config.share_with_current_context ?
                           (MGLSDLContext *)SDL_GL_GetCurrentContext() : NULL;

    context = (MGLSDLContext *)SDL_calloc(1, sizeof(*context));
    if (!context) {
        SDL_OutOfMemory();
        return NULL;
    }

    context->ctx = createGLMContextShared(MGL_BGRA, MGL_UNSIGNED_INT_8_8_8_8_REV, MGL_DEPTH_COMPONENT, MGL_FLOAT,
                                          stencil ? MGL_STENCIL_INDEX8 : 0, stencil ? MGL_UNSIGNED_BYTE : 0,
                                          share ? share->ctx : NULL);
    if (!context->ctx) {
        SDL_free(context);
        SDL_SetError("MooGL couldn't create a context");
        return NULL;
    }

    if (_this->gl_config.flags & SDL_GL_CONTEXT_DEBUG_FLAG) {
        flags |= MGL_CONTEXT_FLAG_DEBUG_BIT;
    }
    if (_this->gl_config.no_error) {
        flags |= MGL_CONTEXT_FLAG_NO_ERROR_BIT;
    }
    if (flags) {
        MGLsetContextFlags(context->ctx, flags);
    }

    MGLRenderer *renderer = [[MGLRenderer alloc] init];
    [renderer createMGLRendererAndBindToContext:context->ctx view:data.sdlContentView];
    context->renderer = (void *)CFBridgingRetain(renderer);
    context->window = window;

    if (Cocoa_GL_MakeCurrent(_this, window, context) < 0) {
        Cocoa_GL_DeleteContext(_this, context);
        return NULL;
    }

    /* SDL reports what was asked for; the context is 4.6 core */
    _this->gl_config.major_version = 4;
    _this->gl_config.minor_version = 6;
    _this->gl_config.profile_mask = SDL_GL_CONTEXT_PROFILE_CORE;

    return context;
}}

int Cocoa_GL_MakeCurrent(_THIS, SDL_Window * window, SDL_GLContext context)
{
    MGLSDLContext *mgl = (MGLSDLContext *)context;

    if (!mgl) {
        MGLsetCurrentContext(PlaceholderContext());
        return 0;
    }

    /* a MooGL context draws into the view it was made for */
    if (window && window != mgl->window) {
        return SDL_SetError("MooGL: a context can only be current on the window it was created for");
    }

    MGLsetCurrentContext(mgl->ctx);
    return 0;
}

int Cocoa_GL_SetSwapInterval(_THIS, int interval)
{
    MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();

    if (!mgl) {
        return SDL_SetError("No current OpenGL context");
    }

    /* adaptive vsync (-1) waits like 1 */
    mgl->interval = interval;
    MGLsetSwapInterval(mgl->ctx, interval < 0 ? 1 : interval);
    return 0;
}

int Cocoa_GL_GetSwapInterval(_THIS)
{
    MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();
    return mgl ? mgl->interval : 0;
}

int Cocoa_GL_SwapWindow(_THIS, SDL_Window * window)
{ @autoreleasepool
{
    MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();
    SDL_WindowData *data = (__bridge SDL_WindowData *)window->driverdata;

    if (!mgl) {
        return SDL_SetError("No current OpenGL context");
    }

    /* Metal only paces a layer the system is showing, so a hidden window or
       one on another space is paced here; a deadline, so one long sleep does
       not push every later frame out */
    if (mgl->interval != 0) {
        const double rate = data.nswindow.screen.maximumFramesPerSecond > 0 ?
                            (double)data.nswindow.screen.maximumFramesPerSecond : 60.0;
        const double period = SDL_abs(mgl->interval) / rate;
        const double now = (double)SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency();

        if (mgl->next_swap <= 0.0 || mgl->next_swap + period < now) {
            mgl->next_swap = now;
        } else if (now < mgl->next_swap) {
            usleep((useconds_t)((mgl->next_swap - now) * 1e6));
        }
        mgl->next_swap += period;
    }

    MGLswapBuffers(mgl->ctx);
    return 0;
}}

void Cocoa_GL_DeleteContext(_THIS, SDL_GLContext context)
{ @autoreleasepool
{
    MGLSDLContext *mgl = (MGLSDLContext *)context;

    if (!mgl) {
        return;
    }

    if (SDL_GL_GetCurrentContext() == context) {
        MGLsetCurrentContext(PlaceholderContext());
    }

    destroyGLMContext(mgl->ctx);
    if (mgl->renderer) {
        CFRelease(mgl->renderer);
    }
    SDL_free(mgl);
}}

#endif /* SDL_VIDEO_OPENGL_CGL */

/* vi: set ts=4 sw=4 expandtab: */
