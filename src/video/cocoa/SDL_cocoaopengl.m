/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

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
#include "SDL_internal.h"

// MooGL implementation of SDL OpenGL support: OpenGL 4.6 on Metal in place
// of Apple's NSOpenGL. Modified from SDL's NSOpenGL version for MooGL.

#ifdef SDL_VIDEO_OPENGL_CGL
#include "SDL_cocoavideo.h"
#include "SDL_cocoaopengl.h"

#include <dlfcn.h>
#include <unistd.h>

#import <QuartzCore/QuartzCore.h>

// From libmoogl. MGLRenderer.h needs Metal's headers, so the few calls used
// here are declared instead.
typedef struct GLMContextRec_t *GLMContext;
extern GLMContext createGLMContext(unsigned format, unsigned type, unsigned depth_format, unsigned depth_type,
                                   unsigned stencil_format, unsigned stencil_type);
extern GLMContext createGLMContextProfile(unsigned format, unsigned type, unsigned depth_format, unsigned depth_type,
                                          unsigned stencil_format, unsigned stencil_type, GLMContext share,
                                          unsigned profile);
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
    void *renderer;         // MGLRenderer, retained
    SDL_Window *window;     // the window whose view it draws into
    int interval;
    double next_swap;
} MGLSDLContext;

// MooGL has to have a context current for the GL entry points to land
// anywhere, so this stands in when the app has none
static GLMContext PlaceholderContext(void)
{
    static GLMContext placeholder = NULL;

    if (placeholder == NULL) {
        placeholder = createGLMContext(0, 0, 0, 0, 0, 0);
    }
    return placeholder;
}

bool Cocoa_GL_LoadLibrary(SDL_VideoDevice *_this, const char *path)
{
    Dl_info info;

    // always the copy of libmoogl SDL is linked against; a second copy would
    // have its own current context
    (void)path;
    if (!dladdr((const void *)createGLMContext, &info) || !info.dli_fname) {
        return SDL_SetError("MooGL: can't find libmoogl");
    }

    _this->gl_config.dll_handle = dlopen(info.dli_fname, RTLD_LAZY | RTLD_LOCAL);
    if (!_this->gl_config.dll_handle) {
        return SDL_SetError("MooGL: %s", dlerror());
    }
    SDL_strlcpy(_this->gl_config.driver_path, info.dli_fname, SDL_arraysize(_this->gl_config.driver_path));
    return true;
}

SDL_FunctionPointer Cocoa_GL_GetProcAddress(SDL_VideoDevice *_this, const char *proc)
{
    return (SDL_FunctionPointer)dlsym(_this->gl_config.dll_handle, proc);
}

void Cocoa_GL_UnloadLibrary(SDL_VideoDevice *_this)
{
    if (_this->gl_config.dll_handle) {
        dlclose(_this->gl_config.dll_handle);
    }
    _this->gl_config.dll_handle = NULL;
}

SDL_GLContext Cocoa_GL_CreateContext(SDL_VideoDevice *_this, SDL_Window *window)
{
    @autoreleasepool {
        SDL_CocoaWindowData *data = (__bridge SDL_CocoaWindowData *)window->internal;
        const int major = _this->gl_config.major_version;
        const int minor = _this->gl_config.minor_version;
        const bool stencil = _this->gl_config.stencil_size > 0;
        unsigned flags = 0;
        MGLSDLContext *context;

        if (_this->gl_config.profile_mask == SDL_GL_CONTEXT_PROFILE_ES) {
            SDL_SetError("MooGL has no OpenGL ES");
            return NULL;
        }

        // every request up to 4.6 gets 4.6
        if (major > 4 || (major == 4 && minor > 6)) {
            SDL_SetError("OpenGL %d.%d is newer than MooGL's 4.6", major, minor);
            return NULL;
        }

        MGLSDLContext *share = _this->gl_config.share_with_current_context ?
                               (MGLSDLContext *)SDL_GL_GetCurrentContext() : NULL;

        context = (MGLSDLContext *)SDL_calloc(1, sizeof(*context));
        if (!context) {
            return NULL;
        }

        // a core context only when asked for one; otherwise the old calls work too
        const bool compat = _this->gl_config.profile_mask != SDL_GL_CONTEXT_PROFILE_CORE;

        context->ctx = createGLMContextProfile(MGL_BGRA, MGL_UNSIGNED_INT_8_8_8_8_REV, MGL_DEPTH_COMPONENT, MGL_FLOAT,
                                               stencil ? MGL_STENCIL_INDEX8 : 0, stencil ? MGL_UNSIGNED_BYTE : 0,
                                               share ? share->ctx : NULL, compat ? 0x2 : 0x1);
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

        if (!Cocoa_GL_MakeCurrent(_this, window, (SDL_GLContext)context)) {
            Cocoa_GL_DestroyContext(_this, (SDL_GLContext)context);
            return NULL;
        }

        // the context is 4.6, core or compatibility
        _this->gl_config.major_version = 4;
        _this->gl_config.minor_version = 6;
        _this->gl_config.profile_mask = compat ? SDL_GL_CONTEXT_PROFILE_COMPATIBILITY : SDL_GL_CONTEXT_PROFILE_CORE;

        return (SDL_GLContext)context;
    }
}

bool Cocoa_GL_MakeCurrent(SDL_VideoDevice *_this, SDL_Window *window, SDL_GLContext context)
{
    MGLSDLContext *mgl = (MGLSDLContext *)context;

    if (!mgl) {
        MGLsetCurrentContext(PlaceholderContext());
        return true;
    }

    // a MooGL context draws into the view it was made for
    if (window && window != mgl->window) {
        return SDL_SetError("MooGL: a context can only be current on the window it was created for");
    }

    MGLsetCurrentContext(mgl->ctx);
    return true;
}

bool Cocoa_GL_SetSwapInterval(SDL_VideoDevice *_this, int interval)
{
    MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();

    if (!mgl) {
        return SDL_SetError("No current OpenGL context");
    }

    // adaptive vsync (-1) waits like 1
    mgl->interval = interval;
    MGLsetSwapInterval(mgl->ctx, interval < 0 ? 1 : interval);
    return true;
}

bool Cocoa_GL_GetSwapInterval(SDL_VideoDevice *_this, int *interval)
{
    MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();

    if (!mgl) {
        return SDL_SetError("no OpenGL context");
    }
    *interval = mgl->interval;
    return true;
}

bool Cocoa_GL_SwapWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    @autoreleasepool {
        MGLSDLContext *mgl = (MGLSDLContext *)SDL_GL_GetCurrentContext();
        SDL_CocoaWindowData *data = (__bridge SDL_CocoaWindowData *)window->internal;

        if (!mgl) {
            return SDL_SetError("No current OpenGL context");
        }

        // Metal only paces a layer the system is showing, so a hidden window or
        // one on another space is paced here; a deadline, so one long sleep does
        // not push every later frame out
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
        return true;
    }
}

bool Cocoa_GL_DestroyContext(SDL_VideoDevice *_this, SDL_GLContext context)
{
    @autoreleasepool {
        MGLSDLContext *mgl = (MGLSDLContext *)context;

        if (!mgl) {
            return true;
        }

        if (SDL_GL_GetCurrentContext() == context) {
            MGLsetCurrentContext(PlaceholderContext());
        }

        destroyGLMContext(mgl->ctx);
        if (mgl->renderer) {
            CFRelease(mgl->renderer);
        }
        SDL_free(mgl);
        return true;
    }
}

#endif // SDL_VIDEO_OPENGL_CGL
