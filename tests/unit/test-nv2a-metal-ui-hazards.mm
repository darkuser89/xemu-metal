/* Offscreen Metal 4 VGA/UI dependency checks; no app, window or VM.
 * SPDX-License-Identifier: GPL-2.0-or-later */
#import "hw/xbox/nv2a/pgraph/metal/display.h"
#import "hw/xbox/nv2a/pgraph/metal/vga.h"
#import "ui/xui/metal4/decal.h"
#import "ui/xui/metal4/imgui-renderer.h"
#import <objc/runtime.h>
#include <imgui.h>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <initializer_list>

static const unsigned side = 16, frames = 8, pixels = side * side;
static BOOL production, broad;
static MTLStages expectedStages;
static unsigned consumers, producers, callbacks;
static id<MTL4RenderCommandEncoder> callbackEncoder;
static id<MTL4ArgumentTable> callbackArguments;
static id<MTLRenderPipelineState> callbackPipeline;
static Class encoderClasses[2];
static unsigned classCount;
typedef void (*BarrierIMP)(id, SEL, MTLStages, MTLStages,
                           MTL4VisibilityOptions);
static BarrierIMP originalConsumers[2], originalProducers[2];

@interface UICommands : NV2AMetalCommands
@property(nonatomic) BOOL dedicatedUploads;
@property(nonatomic) BOOL failUpload;
@property(nonatomic) NSUInteger failUploadAt;
@property(nonatomic) unsigned uploadDepth;
@property(nonatomic, strong) NSMutableArray<NSArray *> *uploads;
@end

@implementation UICommands
- (id<MTLBuffer>)uploadBytes:(const void *)bytes
                      length:(NSUInteger)length
                      offset:(NSUInteger *)offset
                       error:(NSError **)error
{
    if (_failUpload || (!_uploadDepth && _failUploadAt &&
                        _uploads.count == _failUploadAt - 1)) {
        if (error)
            *error = [NSError errorWithDomain:@"test.ui-upload"
                                         code:1
                                     userInfo:nil];
        return nil;
    }
    BOOL outer = !_uploadDepth++;
    id<MTLBuffer> buffer;
    if (_dedicatedUploads) {
        buffer = [self.device newBufferWithBytes:bytes
                                          length:length
                                         options:MTLResourceStorageModeShared];
        assert(buffer && [self addResource:buffer error:error]);
        *offset = 0;
    } else {
        buffer = [super uploadBytes:bytes
                             length:length
                             offset:offset
                              error:error];
    }
    assert(buffer && *offset <= buffer.length &&
           length <= buffer.length - *offset && !(*offset & 255));
    /* The arena re-enters uploadBytes when it rolls to another page. Count
     * only the caller's immutable slice, not that internal retry. */
    if (outer) {
        [_uploads addObject:@[
            buffer, @(*offset), [NSData dataWithBytes:bytes length:length]
        ]];
    }
    _uploadDepth--;
    return buffer;
}
@end

static unsigned uploadRecords, arenaRecords, arenaPages, nonzeroOffsets;
static unsigned geometryRecords;
static void check_uploads(UICommands *commands, id<MTLBuffer> paddedPage)
{
    NSMutableSet *buffers = [NSMutableSet new];
    id<MTLBuffer> page = paddedPage;
    NSUInteger next = page ? page.length - 256 : 0;
    for (NSArray *record in commands.uploads) {
        id<MTLBuffer> buffer = record[0];
        NSUInteger offset = [record[1] unsignedIntegerValue];
        NSData *bytes = record[2];
        assert(!memcmp((char *)buffer.contents + offset, bytes.bytes,
                       bytes.length));
        NSValue *identity = [NSValue valueWithNonretainedObject:buffer];
        uploadRecords++;
        if (commands.dedicatedUploads) {
            assert(!offset);
        } else {
            assert(page && next <= page.length);
            if (bytes.length > page.length - next) {
                assert(buffer != page && buffer != paddedPage &&
                       buffer.length == paddedPage.length &&
                       ![buffers containsObject:identity]);
                page = buffer;
                next = 0;
            }
            assert(buffer == page && offset == next);
            next += (bytes.length + 255) & ~(NSUInteger)255;
            nonzeroOffsets += offset != 0;
        }
        [buffers addObject:identity];
    }
    if (commands.dedicatedUploads) {
        assert(buffers.count == commands.uploads.count);
    } else if (commands.uploads.count) {
        assert(commands.uploads.count >= frames);
        arenaRecords += commands.uploads.count;
        arenaPages += buffers.count;
    }
}

static void require(BOOL ok, NSError *error)
{
    if (!ok) {
        fprintf(stderr, "UI hazards: %s\n",
                error.localizedDescription.UTF8String);
        abort();
    }
}
static unsigned class_index(id object)
{
    for (unsigned i = 0; i < classCount; i++)
        if (object_getClass(object) == encoderClasses[i])
            return i;
    abort();
}
static void consumer(id object, SEL selector, MTLStages after, MTLStages before,
                     MTL4VisibilityOptions options)
{
    if (production) {
        assert(after == MTLStageAll && before == expectedStages &&
               options == MTL4VisibilityOptionDevice);
        consumers++;
        if (expectedStages & MTLStageVertex)
            callbackEncoder = (id<MTL4RenderCommandEncoder>)object;
        if (broad)
            before = MTLStageAll;
    }
    originalConsumers[class_index(object)](object, selector, after, before,
                                           options);
}
static void producer(id object, SEL selector, MTLStages after, MTLStages before,
                     MTL4VisibilityOptions options)
{
    if (production) {
        assert(after == expectedStages && before == MTLStageAll &&
               options == MTL4VisibilityOptionDevice);
        producers++;
        if (broad)
            after = MTLStageAll;
    }
    originalProducers[class_index(object)](object, selector, after, before,
                                           options);
    if (production && (expectedStages & MTLStageVertex))
        callbackEncoder = nil;
}
static void callback(const ImDrawList *, const ImDrawCmd *)
{
    assert(callbackEncoder && callbackArguments && callbackPipeline);
    [callbackEncoder setRenderPipelineState:callbackPipeline];
    [callbackEncoder setArgumentTable:callbackArguments
                             atStages:MTLRenderStageVertex];
    [callbackEncoder drawPrimitives:MTLPrimitiveTypePoint
                        vertexStart:0
                        vertexCount:1];
    callbacks++;
}
static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format)
{
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:side
                                                          height:side
                                                       mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
              MTLTextureUsageRenderTarget;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    assert(result);
    return result;
}
static void install_spies(NV2AMetalCommands *commands, id<MTLTexture> target)
{
    NSError *error = nil;
    require([commands beginWithError:&error] != nil, error);
    require([commands addResource:target error:&error], error);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    id<MTL4RenderCommandEncoder> render =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    assert(render);
    encoderClasses[classCount++] = object_getClass(render);
    [render endEncoding];
    id<MTL4ComputeCommandEncoder> compute =
        [commands.commandBuffer computeCommandEncoder];
    assert(compute);
    if (object_getClass(compute) != encoderClasses[0])
        encoderClasses[classCount++] = object_getClass(compute);
    [compute endEncoding];
    [commands cancel];
    SEL selectors[] = {
        @selector(barrierAfterQueueStages:beforeStages:visibilityOptions:),
        @selector(barrierAfterStages:beforeQueueStages:visibilityOptions:)
    };
    /* Capture inherited implementations before overriding either class. */
    for (unsigned i = 0; i < classCount; i++) {
        originalConsumers[i] = (BarrierIMP)class_getMethodImplementation(
            encoderClasses[i], selectors[0]);
        originalProducers[i] = (BarrierIMP)class_getMethodImplementation(
            encoderClasses[i], selectors[1]);
        assert(originalConsumers[i] && originalProducers[i]);
    }
    for (unsigned i = 0; i < classCount; i++)
        for (unsigned j = 0; j < 2; j++) {
            Method m = class_getInstanceMethod(encoderClasses[i], selectors[j]);
            IMP original =
                (IMP)(j ? originalProducers[i] : originalConsumers[i]);
            class_addMethod(encoderClasses[i], selectors[j], original,
                            method_getTypeEncoding(m));
            method_setImplementation(
                class_getInstanceMethod(encoderClasses[i], selectors[j]),
                j ? (IMP)producer : (IMP)consumer);
        }
}
static void restore_spies(void)
{
    for (unsigned i = 0; i < classCount; i++) {
        method_setImplementation(
            class_getInstanceMethod(
                encoderClasses[i],
                @selector(
                    barrierAfterQueueStages:beforeStages:visibilityOptions:)),
            (IMP)originalConsumers[i]);
        method_setImplementation(
            class_getInstanceMethod(
                encoderClasses[i],
                @selector(
                    barrierAfterStages:beforeQueueStages:visibilityOptions:)),
            (IMP)originalProducers[i]);
    }
}
static uint32_t source_color(unsigned x, unsigned y, unsigned frame)
{
    return (((x / 4 + frame) & 1) ? 255u : 0u) |
           (((y / 4 + (frame >> 1)) & 1) ? 0xff00u : 0u) |
           (((frame >> 2) & 1) ? 0xff0000u : 0u) | 0xff000000u;
}
static uint32_t base_color(unsigned frame)
{
    return 0xffff0000u | ((frame & 1) ? 255u : 0u);
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        UICommands *commands = [[UICommands alloc] initWithError:&error];
        require(commands != nil, error);
        commands.uploads = [NSMutableArray new];
        id<MTLDevice> device = commands.device;
        NSString *source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void seed(constant uint4 &p [[buffer(0)]],device uint "
             "*raw [[buffer(1)]],"
             "device uint *callback_data [[buffer(2)]],"
             "texture2d<float,access::write> src [[texture(0)]],"
             "texture2d<float,access::write> main [[texture(1)]],"
             "texture2d<float,access::write> overlay [[texture(2)]],"
             "uint id [[thread_position_in_grid]]){if(id>=p.y*p.y)return;"
             "uint2 xy=uint2(id%p.y,id/p.y);"
             "uint "
             "r=((xy.x/4+p.x)&1)*255,g=((xy.y/"
             "4+(p.x>>1))&1)*255,b=((p.x>>2)&1)*255;"
             "raw[id]=b|(g<<8)|(r<<16)|0xff000000u;"
             "if(id==0)callback_data[p.x]=0xd3c0a500u^p.x;"
             "src.write(float4(r,g,b,255)/255.0f,xy);"
             "float4 "
             "c=float4(p.x&1,0,1,1);main.write(c,xy);overlay.write(c,xy);}\n"
             "kernel void consume(texture2d<float,access::read> main "
             "[[texture(0)]],"
             "texture2d<float,access::read> overlay [[texture(1)]],"
             "device uint *out [[buffer(0)]],constant uint4 &p [[buffer(1)]],"
             "device const uint *callback_data [[buffer(2)]],"
             "uint id [[thread_position_in_grid]]){if(id>=p.y*p.y)return;"
             "uint2 xy=uint2(id%p.y,id/p.y);"
             "uint4 "
             "c=uint4(round(main.read(xy)*255.0f)),d=uint4(round(overlay.read("
             "xy)*255.0f));"
             "out[(p.x*2)*p.y*p.y+id]=c.x|(c.y<<8)|(c.z<<16)|(c.w<<24);"
             "out[(p.x*2+1)*p.y*p.y+id]=d.x|(d.y<<8)|(d.z<<16)|(d.w<<24);"
             "if(id==0)out[p.w*2*p.y*p.y+p.x]=p.z?callback_data[p.x]:("
             "0xd3c0a500u^p.x);}\n"
             "struct CallbackVertex{float4 p [[position]];float size "
             "[[point_size]];};"
             "vertex CallbackVertex callback_vertex(device const uint *raw "
             "[[buffer(0)]],"
             "device uint *out [[buffer(1)]],constant uint4 &p [[buffer(2)]],"
             "uint id [[vertex_id]]){if(id==0)out[p.x]="
             "raw[(p.x*37+5)%(p.y*p.y)]^(p.x*0x9e3779b9u);"
             "return {float4(2,2,.5f,1),1};}\n"
             "fragment float4 callback_fragment(){return float4(0);}\n";
        id<MTL4Compiler> compiler =
            [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                        error:&error];
        require(compiler != nil, error);
        MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
        ld.source = source;
        ld.options = [MTLCompileOptions new];
        ld.options.languageVersion = MTLLanguageVersion4_0;
        id<MTLLibrary> library = [compiler newLibraryWithDescriptor:ld
                                                              error:&error];
        require(library != nil, error);
        id<MTLComputePipelineState> pipelines[2];
        for (unsigned i = 0; i < 2; i++) {
            MTL4LibraryFunctionDescriptor *fn =
                [MTL4LibraryFunctionDescriptor new];
            fn.library = library;
            fn.name = i ? @"consume" : @"seed";
            MTL4ComputePipelineDescriptor *pd =
                [MTL4ComputePipelineDescriptor new];
            pd.computeFunctionDescriptor = fn;
            pipelines[i] =
                [compiler newComputePipelineStateWithDescriptor:pd
                                            compilerTaskOptions:nil
                                                          error:&error];
            require(pipelines[i] != nil, error);
        }
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
        ad.maxBufferBindCount = 3;
        ad.maxTextureBindCount = 3;
        ad.initializeBindings = YES;
        id<MTL4ArgumentTable> args =
            [device newArgumentTableWithDescriptor:ad error:&error];
        require(args != nil, error);
        callbackArguments = [device newArgumentTableWithDescriptor:ad
                                                             error:&error];
        require(callbackArguments != nil, error);
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = io.LogFilename = nullptr;
        io.DisplaySize = ImVec2(side, side);
        io.DeltaTime = 1.0f / 60;
        NV2AMetalVGA *vga = [[NV2AMetalVGA alloc] initWithDevice:device
                                                           error:&error];
        require(vga != nil, error);
        unsigned pairs = 0, checked = 0, wantedPasses = 0, wantedCallbacks = 0,
                 callbackRecords = 0;
        for (MTLPixelFormat format :
             { MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm }) {
            MTL4LibraryFunctionDescriptor *vf = [MTL4LibraryFunctionDescriptor
                                              new],
                                          *ff = [MTL4LibraryFunctionDescriptor
                                              new];
            vf.library = ff.library = library;
            vf.name = @"callback_vertex";
            ff.name = @"callback_fragment";
            MTL4RenderPipelineDescriptor *pd =
                [MTL4RenderPipelineDescriptor new];
            pd.vertexFunctionDescriptor = vf;
            pd.fragmentFunctionDescriptor = ff;
            pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassPoint;
            pd.colorAttachments[0].pixelFormat = format;
            callbackPipeline =
                [compiler newRenderPipelineStateWithDescriptor:pd
                                           compilerTaskOptions:nil
                                                         error:&error];
            require(callbackPipeline != nil, error);
            NV2AMetalDisplay *display =
                [[NV2AMetalDisplay alloc] initWithDevice:device
                                             pixelFormat:format
                                                   error:&error];
            XemuMetal4Decals *decals =
                [[XemuMetal4Decals alloc] initWithDevice:device
                                             pixelFormat:format
                                                   error:&error];
            XemuMetal4ImGui *imgui =
                [[XemuMetal4ImGui alloc] initWithDevice:device
                                            pixelFormat:format
                                                  error:&error];
            require(display && decals && imgui &&
                        [imgui newFrameWithError:&error],
                    error);
            id<MTLTexture> main = texture(device, format),
                           overlay = texture(device, format),
                           src = texture(device, format);
            id<MTLBuffer> raw =
                [device newBufferWithLength:pixels * 4
                                    options:MTLResourceStorageModePrivate];
            id<MTLBuffer> output =
                [device newBufferWithLength:(frames * 2 * pixels + frames) * 4
                                    options:MTLResourceStorageModeShared];
            id<MTLBuffer> callbackData =
                [device newBufferWithLength:frames * 4
                                    options:MTLResourceStorageModePrivate];
            assert(raw && output && callbackData);
            if (!classCount)
                install_spies(commands, main);
            /* A failed upload must leave no open encoder and must permit a
             * cancelled recording to be retried with fresh uniforms. */
            require([commands beginWithError:&error] != nil, error);
            commands.failUpload = YES;
            XemuMetal4Decal *failed = [XemuMetal4Decal new];
            failed.texture = src;
            failed.destination = failed.source = CGRectMake(0, 0, side, side);
            error = nil;
            assert(![decals encodeDecals:@[ failed ]
                                commands:commands
                                  target:overlay
                                   clear:YES
                                   error:&error]);
            assert([error.domain isEqualToString:@"test.ui-upload"]);
            ImGui::NewFrame();
            ImGui::GetBackgroundDrawList()->AddRectFilled(
                ImVec2(0, 0), ImVec2(side, side), IM_COL32_WHITE);
            ImGui::Render();
            error = nil;
            assert(![imgui encodeDrawData:ImGui::GetDrawData()
                                 commands:commands
                                   target:main
                                    error:&error]);
            assert([error.domain isEqualToString:@"test.ui-upload"]);
            [commands cancel];
            commands.failUpload = NO;
            for (NSUInteger upload = 2; upload <= 3; upload++) {
                [commands.uploads removeAllObjects];
                commands.failUploadAt = upload;
                require([commands beginWithError:&error] != nil, error);
                error = nil;
                assert(![imgui encodeDrawData:ImGui::GetDrawData()
                                     commands:commands
                                       target:main
                                        error:&error]);
                assert([error.domain isEqualToString:@"test.ui-upload"] &&
                       commands.uploads.count == upload - 1);
                id<MTL4ComputeCommandEncoder> after =
                    [commands.commandBuffer computeCommandEncoder];
                assert(after);
                [after endEncoding];
                [commands cancel];
            }
            commands.failUploadAt = 0;
            for (unsigned route = 0; route < 5; route++)
                for (unsigned scene = 0; scene < (route >= 3 ? 32 : 16);
                     scene++) {
                    BOOL off = scene & 1, emptyDecals = scene & 2,
                         clear = !(scene & 4), emptyImGui = scene & 8,
                         opaqueCallback = scene & 16;
                    if (route == 3 && emptyImGui)
                        continue;
                    NSData *reference = nil;
                    for (unsigned variant = 0; variant < 4; variant++) {
                        broad = !(variant & 1) ^ !!(scene & 1);
                        commands.dedicatedUploads = variant & 2;
                        [commands.uploads removeAllObjects];
                        memset(output.contents, 0x5a, output.length);
                        require([commands beginWithError:&error] != nil, error);
                        /* Leave space for one small slice to exercise rollover
                         * before or after the first upload, depending on size. */
                        id<MTLBuffer> paddedPage = nil;
                        if (!commands.dedicatedUploads) {
                            unsigned char padding[65536 - 256];
                            memset(padding, 0x5a, sizeof(padding));
                            NSUInteger offset = 1;
                            paddedPage = [commands uploadBytes:padding
                                                        length:sizeof(padding)
                                                        offset:&offset
                                                         error:&error];
                            require(paddedPage != nil, error);
                            assert(offset == 0);
                            [commands.uploads removeAllObjects];
                        }
                        for (id<MTLResource> r in
                             @[ main, overlay, src, raw, output, callbackData ])
                            require([commands addResource:r error:&error],
                                    error);
                        require([commands keepAlive:args error:&error], error);
                        require([commands keepAlive:callbackArguments
                                              error:&error],
                                error);
                        for (unsigned frame = 0; frame < frames; frame++) {
                            BOOL gpuCallback =
                                route >= 3 && !emptyImGui && opaqueCallback;
                            uint32_t values[] = { frame, side, gpuCallback,
                                                  frames };
                            id<MTLBuffer> params = [device
                                newBufferWithBytes:values
                                            length:sizeof(values)
                                           options:
                                               MTLResourceStorageModeShared];
                            require(params && [commands addResource:params
                                                              error:&error],
                                    error);
                            id<MTL4ComputeCommandEncoder> e =
                                [commands.commandBuffer computeCommandEncoder];
                            assert(e);
                            /* Only order the preceding compute readback. The
                             * production encoders must protect their inputs. */
                            [e barrierAfterQueueStages:MTLStageDispatch
                                          beforeStages:MTLStageDispatch
                                     visibilityOptions:
                                         MTL4VisibilityOptionDevice];
                            [args setAddress:params.gpuAddress atIndex:0];
                            [args setAddress:raw.gpuAddress atIndex:1];
                            [args setAddress:callbackData.gpuAddress atIndex:2];
                            [args setTexture:src.gpuResourceID atIndex:0];
                            [args setTexture:main.gpuResourceID atIndex:1];
                            [args setTexture:overlay.gpuResourceID atIndex:2];
                            [e setComputePipelineState:pipelines[0]];
                            [e setArgumentTable:args];
                            [e dispatchThreads:MTLSizeMake(pixels, 1, 1)
                                threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                            [e endEncoding];
                            [callbackArguments setAddress:raw.gpuAddress
                                                  atIndex:0];
                            [callbackArguments
                                setAddress:callbackData.gpuAddress
                                   atIndex:1];
                            [callbackArguments setAddress:params.gpuAddress
                                                  atIndex:2];
                            id<MTLTexture> image = src, result = main;
                            production = YES;
                            if (route == 0 || route == 4) {
                                NV2AMetalVGAUniforms u = {};
                                u.width = u.height = side;
                                u.mode = 32;
                                u.memory_mask = pixels * 4 - 1;
                                NV2AMetalVGARow rows[side];
                                for (unsigned y = 0; y < side; y++)
                                    rows[y] = { y * side * 4, 0 };
                                expectedStages = MTLStageDispatch;
                                image = [vga encodeData:raw
                                                   rows:rows
                                               uniforms:&u
                                               commands:commands
                                                  error:&error];
                                require(image != nil, error);
                                wantedPasses++;
                                if (route == 0)
                                    result = image;
                            }
                            if (route == 1 || route == 4) {
                                NV2AMetalDisplayUniforms u = {};
                                u.scale[0] = u.scale[1] = 1;
                                u.flip_y = frame & 1;
                                for (unsigned i = 0; i < 256; i++)
                                    u.palette[i] = i * 0x010101u;
                                expectedStages = MTLStageFragment;
                                require([display
                                            encodeWithCommands:commands
                                                        source:off ? nil : image
                                                        target:main
                                                      uniforms:&u
                                                        linear:frame & 1
                                                     screenOff:off
                                                         error:&error],
                                        error);
                                wantedPasses++;
                            }
                            if (route == 2 || route == 4) {
                                XemuMetal4Decal *d = [XemuMetal4Decal new];
                                d.texture = image;
                                d.destination = CGRectMake(4, 4, 8, 8);
                                d.source = CGRectMake(0, 0, side, side);
                                d.primary = 0xff0000ff;
                                d.secondary = 0x00ff00ff;
                                d.flipY = frame & 1;
                                d.blend = (XemuMetal4DecalBlend)(frame % 3);
                                expectedStages = MTLStageFragment;
                                require(
                                    [decals
                                        encodeDecals:emptyDecals ? @[] : @[ d ]
                                            commands:commands
                                              target:overlay
                                               clear:clear
                                               error:&error],
                                    error);
                                wantedPasses += !emptyDecals || clear;
                                if (route == 2)
                                    result = overlay;
                            }
                            if (route == 3 || route == 4) {
                                ImGui::NewFrame();
                                if (!emptyImGui) {
                                    ImDrawList *list =
                                        ImGui::GetBackgroundDrawList();
                                    list->Flags &=
                                        ~ImDrawListFlags_AntiAliasedFill;
                                    list->PushClipRect(ImVec2(2, 2),
                                                       ImVec2(14, 14));
                                    list->AddImage(
                                        (ImTextureID)(uintptr_t)(__bridge void
                                                                     *)(route ==
                                                                                3 ?
                                                                            src :
                                                                            overlay),
                                        ImVec2(0, 0), ImVec2(side, side));
                                    list->PopClipRect();
                                    /* A later draw list must also widen the
                                     * pass before its first draw executes. */
                                    ImDrawList *callbackList =
                                        opaqueCallback && (scene & 2) ?
                                            ImGui::GetForegroundDrawList() :
                                            list;
                                    if (opaqueCallback) {
                                        callbackList->AddCallback(callback,
                                                                  nullptr);
                                        wantedCallbacks++;
                                    }
                                    callbackList->AddCallback(
                                        ImDrawCallback_ResetRenderState,
                                        nullptr);
                                    callbackList->AddRectFilled(
                                        ImVec2(12, 0), ImVec2(16, 4),
                                        IM_COL32(0, 255, 0, 255));
                                    wantedPasses++;
                                }
                                ImGui::Render();
                                ImDrawData *data = ImGui::GetDrawData();
                                data->DisplayPos =
                                    ImVec2(frame * 3 + 1, frame * 7 + 2);
                                for (ImDrawList *list : data->CmdLists) {
                                    for (ImDrawVert &v : list->VtxBuffer) {
                                        v.pos.x += data->DisplayPos.x;
                                        v.pos.y += data->DisplayPos.y;
                                    }
                                    for (ImDrawCmd &draw : list->CmdBuffer) {
                                        draw.ClipRect.x += data->DisplayPos.x;
                                        draw.ClipRect.z += data->DisplayPos.x;
                                        draw.ClipRect.y += data->DisplayPos.y;
                                        draw.ClipRect.w += data->DisplayPos.y;
                                    }
                                }
                                expectedStages =
                                    MTLStageFragment |
                                    (opaqueCallback ? MTLStageVertex : 0);
                                NSUInteger upload = commands.uploads.count;
                                require([imgui encodeDrawData:data
                                                     commands:commands
                                                       target:main
                                                        error:&error],
                                        error);
                                if (data->CmdListsCount)
                                    upload++; // Projection.
                                for (const ImDrawList *list : data->CmdLists) {
                                    if (!list->VtxBuffer.Size ||
                                        !list->IdxBuffer.Size)
                                        continue;
                                    assert(upload + 2 <= commands.uploads.count);
                                    NSData *v = commands.uploads[upload++][2];
                                    NSData *i = commands.uploads[upload++][2];
                                    assert(v.length == (NSUInteger)list->VtxBuffer.size_in_bytes() &&
                                           i.length == (NSUInteger)list->IdxBuffer.size_in_bytes() &&
                                           !memcmp(v.bytes, list->VtxBuffer.Data, v.length) &&
                                           !memcmp(i.bytes, list->IdxBuffer.Data, i.length));
                                    geometryRecords += 2;
                                }
                                assert(upload == commands.uploads.count);
                            }
                            production = NO;
                            require([commands addResource:result error:&error],
                                    error);
                            /* No consumer barrier: the production pass must
                             * publish its stores, including clear-only work. */
                            e = [commands.commandBuffer computeCommandEncoder];
                            assert(e);
                            if (route == 2 && emptyDecals && !clear) {
                                /* A no-work pass is not a substitute for the
                                 * original compute producer's dependency. */
                                [e barrierAfterQueueStages:MTLStageDispatch
                                              beforeStages:MTLStageDispatch
                                         visibilityOptions:
                                             MTL4VisibilityOptionDevice];
                            }
                            [args setAddress:output.gpuAddress atIndex:0];
                            [args setAddress:params.gpuAddress atIndex:1];
                            [args setAddress:callbackData.gpuAddress atIndex:2];
                            [args setTexture:result.gpuResourceID atIndex:0];
                            [args setTexture:overlay.gpuResourceID atIndex:1];
                            [e setComputePipelineState:pipelines[1]];
                            [e setArgumentTable:args];
                            [e dispatchThreads:MTLSizeMake(pixels, 1, 1)
                                threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                            [e endEncoding];
                        }
                        check_uploads(commands, paddedPage);
                        require([commands submitWithError:&error], error);
                        require([commands waitUntilIdleWithError:&error],
                                error);
                        const uint32_t *p = (const uint32_t *)output.contents;
                        for (unsigned frame = 0; frame < frames; frame++)
                            for (unsigned y = 0; y < side; y++)
                                for (unsigned x = 0; x < side; x++) {
                                    BOOL center =
                                        x >= 4 && x < 12 && y >= 4 && y < 12;
                                    uint32_t outside =
                                        clear ? 0 : base_color(frame);
                                    uint32_t want =
                                        route == 0 ? source_color(x, y, frame) :
                                        route == 2 ? outside :
                                        route == 3 ? base_color(frame) :
                                        off        ? 0 :
                                                     source_color(
                                                         x,
                                                         frame & 1 ? side - 1 - y : y,
                                                         frame);
                                    BOOL check =
                                        !(route == 2 && center && !emptyDecals);
                                    if ((route == 3 || route == 4) &&
                                        !emptyImGui) {
                                        if (x >= 2 && x < 14 && y >= 2 &&
                                            y < 14) {
                                            if (route == 3)
                                                want =
                                                    source_color(x, y, frame);
                                            else if (center && !emptyDecals)
                                                check = NO;
                                            else if (!clear)
                                                want = outside;
                                        }
                                        if (x >= 12 && y < 4) {
                                            want = 0xff00ff00u;
                                            check = YES;
                                        }
                                    }
                                    NSUInteger at =
                                        (frame * 2) * pixels + y * side + x;
                                    if (check && p[at] != want) {
                                        fprintf(stderr,
                                                "UI route%u scene%u broad%u "
                                                "frame%u xy%u,%u: %08x/%08x\n",
                                                route, scene, broad, frame, x,
                                                y, p[at], want);
                                        abort();
                                    }
                                    uint32_t overlayWant =
                                        route == 2 || route == 4 ?
                                            outside :
                                            base_color(frame);
                                    if (!(center && !emptyDecals &&
                                          (route == 2 || route == 4)))
                                        assert(p[at + pixels] == overlayWant);
                                    checked++;
                                }
                        for (unsigned frame = 0; frame < frames; frame++) {
                            uint32_t want = 0xd3c0a500u ^ frame;
                            if (route >= 3 && !emptyImGui && opaqueCallback) {
                                unsigned at = (frame * 37 + 5) % pixels;
                                uint32_t color =
                                    source_color(at % side, at / side, frame);
                                uint32_t rawColor = (color & 0xff00ff00u) |
                                                    (color & 255u) << 16 |
                                                    (color >> 16 & 255u);
                                uint32_t written =
                                    rawColor ^ (frame * 0x9e3779b9u);
                                assert(written != want);
                                want = written;
                                callbackRecords++;
                            }
                            assert(p[frames * 2 * pixels + frame] == want);
                        }
                        if (!variant)
                            reference = [NSData dataWithBytes:output.contents
                                                       length:output.length];
                        else {
                            assert(!memcmp(reference.bytes, output.contents,
                                           output.length));
                            pairs++;
                        }
                    }
                }
            [imgui shutdown];
        }
        restore_spies();
        callbackEncoder = nil;
        callbackArguments = nil;
        callbackPipeline = nil;
        ImGui::DestroyContext();
        if (pairs != 576 || consumers != wantedPasses ||
            producers != consumers || callbacks != wantedCallbacks)
            fprintf(stderr,
                    "UI totals: pairs %u/576, consumers %u/%u, producers %u, "
                    "callbacks %u/%u\n",
                    pairs, consumers, wantedPasses, producers, callbacks,
                    wantedCallbacks);
        assert(pairs == 576 && consumers == wantedPasses &&
               producers == consumers && callbacks == wantedCallbacks &&
               callbackRecords == callbacks && callbackRecords == 1024);
        assert(uploadRecords && arenaRecords > arenaPages && nonzeroOffsets &&
               geometryRecords);
        printf("Metal UI uploads: %u immutable records, %u arena slices/%u "
               "page uses, %u nonzero offsets; dedicated-buffer equality "
               "and page rollover PASS\n",
               uploadRecords, arenaRecords, arenaPages, nonzeroOffsets);
        printf("Metal ImGui geometry: %u exact vertex/index uploads; both "
               "geometry upload failures end the encoder and cancel PASS\n",
               geometryRecords);
        printf("Metal VGA/UI barriers: %u exact barrier/upload pairs, %u "
               "pixel records, %u consumer/producer pairs, %u callbacks/%u "
               "GPU vertex read-write records; "
               "isolated VGA/Display/Decal/ImGui and full chain, GPU "
               "inputs/readback/overwrite, RGBA/BGRA, "
               "clear/load/screen-off/empty/flip/clip/blend/reset-state PASS; "
               "no window\n",
               pairs, checked, consumers, callbacks, callbackRecords);
    }
    return 0;
}
