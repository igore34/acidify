//
//  Acidify.m
//
//  Created by Igor Gorelik on 1/17/15.
//  Copyright (c) 2015 Igor Gorelik. All rights reserved.
//

#import "Acidify.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <stdint.h>

static Acidify * shared_instance = nil;

//////////////////////////////////////////////////////////////
#pragma mark - Consts & Utils
//////////////////////////////////////////////////////////////
static const unsigned BYTES_PER_PIXEL = 4;
static const unsigned BITS_PER_CHANNEL = 8;
static const unsigned PALETTE_SIZE = 256;
static const unsigned PATTERN_WIDTH = 256;
static const unsigned PATTERN_HEIGHT = 256;
static const NSInteger WINDOW_TAG = 0x04191943;

static float pattern_data[3][PATTERN_WIDTH * PATTERN_HEIGHT];
static float palette_data[PALETTE_SIZE * sizeof(float)];

#define FOREACH_PIXEL(data, w, h) \
    for (int i = 0; i < ((h)/2); i++) {\
        float y = i / (float)((h)/2);\
        for (int j = 0; j< ((w)/2); j++) {\
            float x = j / (float)((w)/2);

#define END_FOREACH_PIXEL(data, w, h, color) \
    (data)[i * w + j] = (color);\
    (data)[i * (w) + ((h) - j - 1)] = (color);\
    (data)[((h) - i - 1) * (w) + j] = (color);\
    (data)[((h) - i - 1) * (w) + ((h) - j - 1)] = (color);}}

typedef struct {
    GLfloat position[2];
    GLfloat uv[2];
} AcidVertex;

typedef struct {
    void* mem;
    
    struct AcidBitmap {
        void* data;
        unsigned width;
        unsigned height;
    } buffers[2];
    
    _Atomic(uint64_t) readIndex;
    _Atomic(uint64_t) writeIndex;
    
} AcidDoubleBuffer;

typedef struct {
    float t0;
    float t1;
} AcidTimePoint;

typedef struct {
    float t;
    
    AcidTimePoint p[3];
} AcidTime;

typedef struct {
    float m[4][4];
} AcidMatrix4;

static const AcidVertex rect_vertices[] = {
    {{-1.f, -1.f}, {0.f, 0.f}},
    {{-1.f,  1.f}, {0.f, 1.f}},
    {{ 1.f, -1.f}, {1.f, 0.f}},
    {{ 1.f,  1.f}, {1.f, 1.f}}
};

static const AcidMatrix4 acid_ident_matrix = {
    .m = {
        {1.f, 0.f, 0.f, 0.f},
        {0.f, 1.f, 0.f, 0.f},
        {0.f, 0.f, 1.f, 0.f},
        {0.f, 0.f, 0.f, 1.f}
    }
};


static inline float acid_dist(float x0, float y0, float x1, float y1) {
    return sqrtf((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
}

static inline float acid_dot(float x0, float y0, float x1, float y1) {
    return x0 * x1 + y0 * y1;
}

static void get_acid_pattern(unsigned index, struct AcidBitmap* bitmap) {
    bitmap->width = PATTERN_WIDTH;
    bitmap->height = PATTERN_HEIGHT;
    bitmap->data = pattern_data[index];
}

static void get_acid_palette(struct AcidBitmap* bitmap) {
    bitmap->width = PALETTE_SIZE;
    bitmap->height = 1;
    bitmap->data = palette_data;
}

static GLint create_acid_shader(GLenum type, const GLchar *text, GLint len) {
    GLint sh = glCreateShader(type);

    glShaderSource(sh, 1, (const char **)&text, &len);
    glCompileShader(sh);

    GLint result;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &result);
    if (result == GL_FALSE) {
        GLint logLen = 0;
        glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &logLen);
        char *log = malloc(logLen);
        glGetShaderInfoLog(sh, logLen, &result, log);
        NSLog(@"Acidify, ERROR: %s", log);
        free(log);
        glDeleteShader(sh);
        return 0;
    }
    
    return sh;
}

static inline void create_buffer(AcidDoubleBuffer* buf, size_t frameSize) {
    buf->mem = malloc(frameSize * 2);
    buf->readIndex = buf->writeIndex = 0;
    buf->buffers[0].data = buf->mem;
    buf->buffers[1].data = buf->mem + frameSize;
}

static inline void free_buffer(AcidDoubleBuffer* buf) {
    free(buf->mem);
    buf->mem = 0;
}

static inline struct AcidBitmap* acquire_read_buffer(AcidDoubleBuffer* buf) {
    if (buf->readIndex != buf->writeIndex)
        return &buf->buffers[buf->readIndex % 2];
    return 0;
}

static inline struct AcidBitmap* acquire_write_buffer(AcidDoubleBuffer* buf) {
    if (buf->readIndex == buf->writeIndex)
        return &buf->buffers[buf->writeIndex % 2];
    return 0;
}

static inline void commit_read_buffer(AcidDoubleBuffer* buf) { ++buf->readIndex; }
static inline void commit_write_buffer(AcidDoubleBuffer* buf) { ++buf->writeIndex; }

static bool check_gl_error() {
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        NSLog(@"Acidify, ERROR: Opengl error=%d", (int)err);
        return true;
    }
    return false;
}

// random float [-1, 1]
static inline float randf11() {
    return 2.f * (rand() / ((float)(RAND_MAX))) - 1.f;
}

static inline void random_time_point(AcidTimePoint* p) {
    static const float maxTime = 1.4f;
    
    p->t0 = randf11() * maxTime;
    p->t1 = randf11() * maxTime;
}

static void start_time(AcidTime* tm) {
    tm->t = 0.f;
    random_time_point(&tm->p[0]);
    random_time_point(&tm->p[1]);
    random_time_point(&tm->p[2]);
}

static void step_time(AcidTime* tm, float dt, AcidTimePoint *current) {
    
    static const float speed = 0.06f;
    tm->t += dt * speed;
    
    if (tm->t >= 1.f) {
        tm->t = 0.f;
        tm->p[0] = tm->p[2];
        random_time_point(&tm->p[1]);
        random_time_point(&tm->p[2]);
        
        *current = tm->p[0];
    } else {
        float t1 = (1 - tm->t);
        float t2 = t1 * t1;
        float tSq = tm->t * tm->t;
        
        current->t0 = t2 * tm->p[0].t0 + 2.f * t1 * tm->t * tm->p[1].t0 + tSq * tm->p[2].t0;
        current->t1 = t2 * tm->p[0].t1 + 2.f * t1 * tm->t * tm->p[1].t1 + tSq * tm->p[2].t1;
    }
}

static void matrix_from_orientation(UIDeviceOrientation orientation, AcidMatrix4 *matrix) {
    memset(matrix->m, 0, sizeof(matrix->m));
    
    switch (orientation) {
        case UIDeviceOrientationPortraitUpsideDown:
            matrix->m[0][0] = -1.f;
            matrix->m[1][1] = -1.f;
            matrix->m[2][2] = 1.f;
            matrix->m[3][3] = 1.f;
            break;
            
        case UIDeviceOrientationLandscapeRight:
            matrix->m[0][1] = -1.f;
            matrix->m[1][0] = 1.f;
            matrix->m[2][2] = 1.f;
            matrix->m[3][3] = 1.f;
            break;
            
        case UIDeviceOrientationLandscapeLeft:
            matrix->m[0][1] = 1.f;
            matrix->m[1][0] = -1.f;
            matrix->m[2][2] = 1.f;
            matrix->m[3][3] = 1.f;
            break;
            
        default:
            matrix->m[0][0] = 1.f;
            matrix->m[1][1] = 1.f;
            matrix->m[2][2] = 1.f;
            matrix->m[3][3] = 1.f;
            break;
    }
}

static UIViewController* find_original_viewcontroller() {
    
    UIViewController* controller = nil;
    
    for (UIWindow* win in [UIApplication sharedApplication].windows) {
        if (win.tag == WINDOW_TAG) {
            continue;
        }
        
        controller = win.rootViewController;
        
        if (win.isKeyWindow) {
            break;
        }
    }
    
    return controller;
}

static void generate_data() {
    static bool is_generated = false;
    if (!is_generated) {
        
        float* color = palette_data;
        for (unsigned i = 0; i < PALETTE_SIZE; ++i) {
            float fi = (float)i;
            *color++ = 1.f - sinf(M_PI * fi / 256.f);
            *color++ = (128.f + 128.f * sinf(M_PI * fi / 128.f))/384.f;
            *color++ = sinf(M_PI * fi / 256.f);
        }
        
        FOREACH_PIXEL(pattern_data[0], PATTERN_WIDTH, PATTERN_HEIGHT)
            float p0x = x - 0.5f - 0.3f * sin(1.4f * M_PI * x + 2.8f);
            float p0y = y - 0.1192f;
            float color = 0.5f * (cosf(sqrtf(acid_dot(p0x, p0y, p0x, p0y)) * 5.6f) + 1.f);
        END_FOREACH_PIXEL(pattern_data[0], PATTERN_WIDTH, PATTERN_HEIGHT, color)
        
        FOREACH_PIXEL(pattern_data[1], PATTERN_WIDTH, PATTERN_HEIGHT)
            float color = 0.6f * cosf(2.12f * acid_dot(x, y, x, y));
        END_FOREACH_PIXEL(pattern_data[1], PATTERN_WIDTH, PATTERN_HEIGHT, color)
        
        FOREACH_PIXEL(pattern_data[2], PATTERN_WIDTH, PATTERN_HEIGHT)
            float color = cosf(acid_dist(x, y, -0.749f, 0.39667f) * 1.3f);
        END_FOREACH_PIXEL(pattern_data[2], PATTERN_WIDTH, PATTERN_HEIGHT, color);

        is_generated = true;
    }
}

//////////////////////////////////////////////////////////////
#pragma mark - Shaders
//////////////////////////////////////////////////////////////
static const GLchar vsh_code[] = "\
    attribute vec2 position; \
    attribute vec2 texCoord; \
    varying vec2 v_texCoord; \
    varying vec2 v_pos; \
    uniform mat4 orientation;\
    \
    void main() { \
        v_texCoord = texCoord; \
        v_pos = position; \
        gl_Position = vec4(position.x, position.y, 0.0, 1.0) * orientation; \
    }";

static const GLchar fsh_code[] = "\
    precision highp float; \
    uniform sampler2D sampler; \
    varying vec4 color; \
    varying vec2 v_texCoord; \
    varying vec2 v_pos; \
    uniform sampler2D snapshot; \
    uniform sampler2D pattern1; \
    uniform sampler2D pattern2; \
    uniform sampler2D pattern3; \
    uniform sampler2D palette; \
    uniform vec2 time; \
    \
    const vec3 one = vec3(1.0);\
    void main() { \
    \
        vec3 wave = vec3(\
            texture2D(pattern1, 0.5 * v_texCoord + vec2(0.0, time.y)).x,\
            texture2D(pattern2, 0.5 * v_texCoord - time).x,\
            texture2D(pattern3, 0.5 * v_texCoord + vec2(time.x, 0.0)).x\
        );\
        float w = dot(wave, one) / 2.8;\
        vec4 waveColor = texture2D(palette, vec2(w * 0.75, 0.0));\
        vec4 color = texture2D(snapshot, v_texCoord + 0.0235 * w);\
        float c = 1.6 * distance(color.xyz, one);\
        gl_FragColor = clamp(mix(color, waveColor, c + 0.05), 0.0, 1.0);\
    }";
//////////////////////////////////////////////////////////////
#pragma mark - AcidView
//////////////////////////////////////////////////////////////
@interface AcidView : UIView
{
    GLuint renderbuffer;
    GLuint framebuffer;
    GLuint texture;
    GLuint pattern[3];
    GLuint palette;
    GLuint vbo;
    GLint program;
    
    int uniformOrientation;
    int uniformSnapshot;
    int uniformTime;
}

- (GLint)loadProgram;

@property (nonatomic, strong) EAGLContext* context;
@property (nonatomic, strong) EAGLContext* prevContext;

- (void)beginGLContext;
- (void)endGLContext;

@end

@implementation AcidView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [self beginGLContext];
    
    glGenRenderbuffers(1, &renderbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    
    [self.context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
    
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);
    
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        
        glDisable(GL_BLEND);
        
        glActiveTexture(GL_TEXTURE0);
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        
        if (check_gl_error()) {
            [self endGLContext];
            return nil;
        }
        
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glViewport(0, 0, frame.size.width, frame.size.height);
        
        glGenTextures(3, &pattern[0]);
        
        for (unsigned i = 0; i < 3; ++i) {
            struct AcidBitmap bitmap;
            get_acid_pattern(i, &bitmap);
            
            glActiveTexture(GL_TEXTURE1 + i);
            glBindTexture(GL_TEXTURE_2D, pattern[i]);
            
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, bitmap.width, bitmap.height, 0, GL_LUMINANCE, GL_FLOAT, bitmap.data);
        }
        

        {   // creating palette
            struct AcidBitmap bitmap;
            get_acid_palette(&bitmap);
            
            glGenTextures(1, &palette);
            glActiveTexture(GL_TEXTURE4);
            glBindTexture(GL_TEXTURE_2D, palette);
            
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
            glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, bitmap.width, bitmap.height, 0, GL_RGB, GL_FLOAT, bitmap.data);
        }
        
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(AcidVertex) * 4, rect_vertices, GL_STATIC_DRAW);
        
        program = [self loadProgram];
        glUseProgram(program);
        if (check_gl_error()) {
            [self endGLContext];
            return nil;
        }
        
        int attrib = glGetAttribLocation(program, "position");
        glEnableVertexAttribArray(attrib);
        glVertexAttribPointer(attrib, 2, GL_FLOAT, GL_FALSE, sizeof(AcidVertex), (GLvoid*)0);
        attrib = glGetAttribLocation(program, "texCoord");
        glEnableVertexAttribArray(attrib);
        glVertexAttribPointer(attrib, 2, GL_FLOAT, GL_FALSE, sizeof(AcidVertex), (GLvoid*)(sizeof(float)*2));
        
        uniformOrientation = glGetUniformLocation(program, "orientation");
        uniformSnapshot = glGetUniformLocation(program, "snapshot");
        uniformTime = glGetUniformLocation(program, "time");
        
        glUniform1i(uniformSnapshot, 0);
        glUniform1i(glGetUniformLocation(program, "pattern1"), 1);
        glUniform1i(glGetUniformLocation(program, "pattern2"), 2);
        glUniform1i(glGetUniformLocation(program, "pattern3"), 3);
        glUniform1i(glGetUniformLocation(program, "palette"), 4);
        glUniformMatrix4fv(uniformOrientation, 1, GL_FALSE, (const GLfloat*)&acid_ident_matrix.m[0][0]);
        
        if (check_gl_error()) {
            [self endGLContext];
            return nil;
        }
        
        [self endGLContext];
        return self;
    } else {
        [self endGLContext];
        NSLog(@"Acidify, ERROR: Incomplete framebuffer");
        return nil;
    }
}

- (void)beginGLContext {
    self.prevContext = [EAGLContext currentContext];
    [EAGLContext setCurrentContext:self.context];
}

- (void)endGLContext {
    [EAGLContext setCurrentContext:self.prevContext];
    self.prevContext = nil;
}

- (void)dealloc {
    [self beginGLContext];
    
    glDeleteProgram(program);
    glDeleteBuffers(1, &vbo);
    glDeleteTextures(1, &palette);
    glDeleteTextures(3, &pattern[0]);
    glDeleteTextures(1, &texture);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteRenderbuffers(1, &renderbuffer);
    self.context = nil;
    
    [self endGLContext];
}

- (GLint)loadProgram {
    GLint vertexShader = create_acid_shader(GL_VERTEX_SHADER, vsh_code, sizeof(vsh_code)/sizeof(vsh_code[0]));
    GLint fragmentShader = create_acid_shader(GL_FRAGMENT_SHADER, fsh_code, sizeof(fsh_code)/sizeof(fsh_code[0]));
    
    if (vertexShader && fragmentShader) {
        GLint prog = glCreateProgram();
        glAttachShader(prog, vertexShader);
        glAttachShader(prog, fragmentShader);
        glDeleteShader(fragmentShader);
        glDeleteShader(vertexShader);
        
        glLinkProgram(prog);
        GLint result = 0;
        glGetProgramiv(prog, GL_LINK_STATUS, &result);
        if (result == GL_FALSE) {
            GLint len = 0;
            glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &len);
            char *log = malloc(len);
            glGetProgramInfoLog(prog, len, &result, log);
            NSLog(@"Acidify, ERROR: Program linking failed: %s", log);
            free(log);
            glDeleteProgram(prog);
            return 0;
        }
        
        return prog;
    }
    
    return 0;
}

- (void)applyOrientation:(AcidMatrix4*)orientationMatrix {
    [self beginGLContext];
    glUseProgram(program);
    glUniformMatrix4fv(uniformOrientation, 1, GL_FALSE, (const GLfloat*)&orientationMatrix->m[0][0]);
    [self endGLContext];
}

- (void)render:(struct AcidBitmap*)bitmap time:(AcidTimePoint)time {
    
    [self beginGLContext];
    
    if (bitmap) {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, bitmap->width, bitmap->height, 0, GL_RGBA, GL_UNSIGNED_BYTE, bitmap->data);
    }
    
    glClearColor(1.f, 1.f, 1.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUniform2f(uniformTime, time.t0, time.t1);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    
    [self.context presentRenderbuffer:GL_RENDERBUFFER];
    [self endGLContext];
}

@end

//////////////////////////////////////////////////////////////
#pragma mark - AcidViewController
//////////////////////////////////////////////////////////////
@interface AcidViewController : UIViewController

@end

@implementation AcidViewController

- (BOOL)shouldAutorotate {
    return NO;
}

@end

//////////////////////////////////////////////////////////////
#pragma mark - Acidify
//////////////////////////////////////////////////////////////
@interface Acidify()

- (id)init;
- (void)dealloc;
- (void)initializeTrip;
- (CGRect)getScreenBounds:(BOOL)isFixedCoords;

- (void)render;
- (void)capture;
- (void)captureScreen;
- (void)screenshot:(CGRect)frame buffer:(struct AcidBitmap*)bitmap;

- (BOOL)canStart;
- (void)startTrip;
- (void)stopTrip;
- (void)suspendTrip;
- (void)delayedTripStart;

- (void)waitForWindow;
- (void)cancelWaitForWindow;
- (void)willResignActive;
- (void)didBecomeActive;
- (void)registerForAppNotifications;
- (void)unregisterForAppNotifications;
- (void)orientationChanged:(NSNotification *)notification;

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) AcidView *view;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CGContextRef screenshotContext;
@property (nonatomic, strong) NSThread *captureThread;
@property (nonatomic, assign) AcidDoubleBuffer snapshotBuffer;
@property (nonatomic, assign) CGColorSpaceRef colorSpaceRef;
@property (nonatomic, assign) AcidTime tripTime;
@property (nonatomic, assign) BOOL isFixedCoords;

@end

//////////////////////////////////////////////////////////////
// Acidify
//////////////////////////////////////////////////////////////
@implementation Acidify


//////////////////////////////////////////////////////////////
#pragma mark - Acidify - Public API
//////////////////////////////////////////////////////////////
+ (void)start {
    if (![NSThread isMainThread])  {
        NSLog(@"Acidify, ERROR: can only start trip on main thread");
        return;
    }
    
    if (!shared_instance)
        shared_instance = [Acidify new];
    
    [shared_instance startTrip];
}

+ (void)stop {
    if (![NSThread isMainThread])  {
        NSLog(@"Acidify, ERROR: can only stop trip on main thread");
        return;
    }
    
    if (shared_instance)
        [shared_instance stopTrip];
}

+ (BOOL)isTripping {
    if (![NSThread isMainThread])  {
        NSLog(@"Acidify, ERROR: can only check trip on main thread");
        return NO;
    }
    
    return shared_instance && shared_instance.window != nil;
}
//////////////////////////////////////////////////////////////



//////////////////////////////////////////////////////////////
#pragma mark - Acidify - Initialization
- (id)init {
    self = [super init];
    _colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    return self;
}

- (void)dealloc {
    CGColorSpaceRelease(_colorSpaceRef);
}

- (CGRect)getScreenBounds:(BOOL)isFixedCoords {
    CGRect bounds = [UIScreen mainScreen].bounds;
    if (isFixedCoords) {
        id<UICoordinateSpace> currentCoordSpace = [[UIScreen mainScreen] coordinateSpace];
        id<UICoordinateSpace> portraitCoordSpace = [[UIScreen mainScreen] fixedCoordinateSpace];
        bounds = [portraitCoordSpace convertRect:[UIScreen mainScreen].bounds fromCoordinateSpace:currentCoordSpace];
    }
    
    return bounds;
}

- (void)initializeTrip {
    
    generate_data();
    
    self.isFixedCoords = [[UIScreen mainScreen] respondsToSelector:@selector(fixedCoordinateSpace)];
    CGRect frame = [self getScreenBounds:self.isFixedCoords];
    
    self.view = [[AcidView alloc] initWithFrame:frame];
    if (!self.view)
    {
        NSLog(@"Acidify, ERROR: view initialization failed.");
        return;
    }
    
    if (self.isFixedCoords) {
        AcidMatrix4 mat;
        matrix_from_orientation((UIDeviceOrientation)[UIApplication sharedApplication].statusBarOrientation, &mat);
        [self.view applyOrientation:&mat];
    }

    self.window = [[UIWindow alloc] initWithFrame:frame];
    self.window.backgroundColor = [UIColor greenColor];
    self.window.windowLevel = UIWindowLevelStatusBar;
    self.window.userInteractionEnabled = NO;
    self.window.rootViewController = [AcidViewController new];
    self.window.tag = WINDOW_TAG;
    self.window.hidden = NO;
    
    [self.window.rootViewController.view addSubview:self.view];
    
    unsigned int width = (unsigned int)self.window.frame.size.width;
    unsigned int height = (unsigned int)self.window.frame.size.height;
    create_buffer(&_snapshotBuffer, width * height * BYTES_PER_PIXEL);
    
    srand((unsigned int)time(0));
    start_time(&_tripTime);
    
    [self captureScreen]; // capturing first frame
    [self render];
    
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(render)];
    [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    self.captureThread = [[NSThread alloc] initWithTarget:self selector:@selector(capture) object:nil];
    [self.captureThread setThreadPriority:1.0];
    [self.captureThread start];
    
    [self registerForAppNotifications];
}

#pragma mark - Acidify - Capture/Render
- (void)screenshot:(CGRect)frame buffer:(struct AcidBitmap*)bitmap {
    bitmap->width = (unsigned)frame.size.width;
    bitmap->height = (unsigned)frame.size.height;

    CGContextRef context = CGBitmapContextCreate(bitmap->data, bitmap->width, bitmap->height,
                                                 BITS_PER_CHANNEL, BYTES_PER_PIXEL * bitmap->width,
                                                 self.colorSpaceRef,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    UIGraphicsPushContext(context);

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.tag == WINDOW_TAG)
            continue;

        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }

    UIGraphicsPopContext();
    CGContextRelease(context);
}

- (void)captureScreen {
    struct AcidBitmap* bitmap = acquire_write_buffer(&_snapshotBuffer);
    if (bitmap) {
        [self screenshot:[UIScreen mainScreen].bounds buffer:bitmap];
        commit_write_buffer(&_snapshotBuffer);
    }
}

- (void)capture {
    while (![[NSThread currentThread] isCancelled]) {
        @autoreleasepool {
            [self captureScreen];
        }
        [NSThread sleepForTimeInterval:0.03];
    }
}

- (void)render {
    AcidTimePoint curTime;
    step_time(&_tripTime, (float)self.displayLink.duration, &curTime);
    
    struct AcidBitmap* bitmap = acquire_read_buffer(&_snapshotBuffer);
    [self.view render:bitmap time:curTime];
    if (bitmap)
        commit_read_buffer(&_snapshotBuffer);
}

#pragma mark - Acidify - Notifications
- (void)willResignActive {
    [self suspendTrip];
}

- (void)didBecomeActive {
    [self startTrip];
}

- (void)orientationChanged:(NSNotification *)notification {
    if (!self.isFixedCoords)
        return;
    
    UIDeviceOrientation newOrientation = [UIDevice currentDevice].orientation;
    NSUInteger mask = [[UIApplication sharedApplication] supportedInterfaceOrientationsForWindow:self.window];
    BOOL shouldAutorotate = YES;
    
    UIViewController* originalController = find_original_viewcontroller();
    if (originalController) {
        mask &= [originalController supportedInterfaceOrientations];
        shouldAutorotate = [originalController shouldAutorotate];
    }
    
    if (shouldAutorotate && (mask & (1 << newOrientation))) {
        AcidMatrix4 mat;
        matrix_from_orientation(newOrientation, &mat);
        [self.view applyOrientation:&mat];
    }
}

- (void)registerForAppNotifications {
    [self unregisterForAppNotifications];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(willResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
}

- (void)unregisterForAppNotifications {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIDeviceOrientationDidChangeNotification
                                                  object:nil];
}

- (void)waitForWindow {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(delayedTripStart)
                                                 name:UIWindowDidBecomeKeyNotification object:nil];
}

- (void)cancelWaitForWindow {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIWindowDidBecomeKeyNotification
                                                  object:nil];
}

#pragma mark - Acidify - Start/Stop Trip
- (BOOL)canStart {
    return [UIApplication sharedApplication].keyWindow != nil;
}

- (void)delayedTripStart {
    [self cancelWaitForWindow];
    [self initializeTrip];
}

- (void)startTrip {
    if (!self.window) {
        if ([self canStart]) {
            [self initializeTrip];
        } else {
            [self waitForWindow];
        }
    }
}

- (void)suspendTrip {
    [self cancelWaitForWindow];
    [self.captureThread cancel];
    
    while (self.captureThread.executing)
        [NSThread sleepForTimeInterval:0.06];
    
    [self.displayLink removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    self.displayLink = nil;
    self.view = nil;
    self.window = nil;
    
    free_buffer(&_snapshotBuffer);
}

- (void)stopTrip {
    [self unregisterForAppNotifications];
    [self suspendTrip];
}

@end
