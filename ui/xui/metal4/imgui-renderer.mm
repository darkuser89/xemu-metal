/*
 * xemu ImGui renderer using the Metal 4 core API
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#import "imgui-renderer.h"
#include "hw/xbox/nv2a/pgraph/metal/texture-alias.h"
#include <imgui.h>
#include "imgui-source.h"
#include <cmath>
#include <cstddef>
#include <cstdint>

static_assert(sizeof(ImDrawIdx) == 2 || sizeof(ImDrawIdx) == 4,
              "Metal indices must be 16 or 32 bits");

static BOOL imgui_error(NSError **error, NSString *message)
{
    if (error) {
        *error =
            [NSError errorWithDomain:@"xemu.ui.metal4"
                                code:1
                            userInfo:@{ NSLocalizedDescriptionKey : message }];
    }
    return NO;
}

@implementation XemuMetal4ImGui {
    ImGuiContext *_context;
    id<MTLDevice> _device;
    MTLPixelFormat _pixelFormat;
    id<MTLRenderPipelineState> _pipeline;
    id<MTL4ArgumentTable> _arguments;
    id<MTLSamplerState> _sampler;
    id<MTLTexture> _fontTexture;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                            pixelFormat:(MTLPixelFormat)pixelFormat
                                  error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }
    IMGUI_CHECKVERSION();
    if (!ImGui::GetCurrentContext() || ImGui::GetIO().BackendRendererUserData) {
        imgui_error(error, @"ImGui requires an unbound current context");
        return nil;
    }
    if (![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4] ||
        !device.hasUnifiedMemory) {
        imgui_error(error, @"Metal 4 ImGui requires Apple Silicon");
        return nil;
    }
    if (pixelFormat != MTLPixelFormatBGRA8Unorm &&
        pixelFormat != MTLPixelFormatRGBA8Unorm) {
        imgui_error(error, @"Metal ImGui requires an unorm RGBA8 target");
        return nil;
    }
    _device = device;
    _pixelFormat = pixelFormat;
    _context = ImGui::GetCurrentContext();
    ImGuiIO &io = ImGui::GetIO();
    io.BackendRendererUserData = (__bridge void *)self;
    io.BackendRendererName = "xemu_metal4";
    io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset;
    return self;
}

- (BOOL)prepareDrawPipelineWithError:(NSError **)error
{
    if (_pipeline) {
        return YES;
    }
    MTL4CompilerDescriptor *compilerDescriptor = [MTL4CompilerDescriptor new];
    compilerDescriptor.label = @"xemu ImGui compiler";
    id<MTL4Compiler> compiler =
        [_device newCompilerWithDescriptor:compilerDescriptor error:error];
    if (!compiler) {
        return NO;
    }
    MTL4LibraryDescriptor *libraryDescriptor = [MTL4LibraryDescriptor new];
    libraryDescriptor.source = @(metal_shader_source);
    libraryDescriptor.options = [MTLCompileOptions new];
    libraryDescriptor.options.languageVersion = MTLLanguageVersion4_0;
    libraryDescriptor.options.mathMode = MTLMathModeSafe;
    id<MTLLibrary> library =
        [compiler newLibraryWithDescriptor:libraryDescriptor error:error];
    if (!library) {
        return NO;
    }
    MTL4LibraryFunctionDescriptor *vertex = [MTL4LibraryFunctionDescriptor new];
    vertex.library = library;
    vertex.name = @"xemu_imgui_vertex";
    MTL4LibraryFunctionDescriptor *fragment =
        [MTL4LibraryFunctionDescriptor new];
    fragment.library = library;
    fragment.name = @"xemu_imgui_fragment";
    MTLVertexDescriptor *layout = [MTLVertexDescriptor new];
    layout.attributes[0].offset = offsetof(ImDrawVert, pos);
    layout.attributes[0].format = MTLVertexFormatFloat2;
    layout.attributes[1].offset = offsetof(ImDrawVert, uv);
    layout.attributes[1].format = MTLVertexFormatFloat2;
    layout.attributes[2].offset = offsetof(ImDrawVert, col);
    layout.attributes[2].format = MTLVertexFormatUChar4Normalized;
    layout.layouts[0].stride = sizeof(ImDrawVert);
    MTL4RenderPipelineDescriptor *pipelineDescriptor =
        [MTL4RenderPipelineDescriptor new];
    pipelineDescriptor.label = @"xemu ImGui triangles";
    pipelineDescriptor.vertexDescriptor = layout;
    pipelineDescriptor.vertexFunctionDescriptor = vertex;
    pipelineDescriptor.fragmentFunctionDescriptor = fragment;
    pipelineDescriptor.inputPrimitiveTopology =
        MTLPrimitiveTopologyClassTriangle;
    MTL4RenderPipelineColorAttachmentDescriptor *color =
        pipelineDescriptor.colorAttachments[0];
    color.pixelFormat = _pixelFormat;
    color.blendingState = MTL4BlendStateEnabled;
    color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> pipeline =
        [compiler newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                   compilerTaskOptions:nil
                                                 error:error];
    if (!pipeline) {
        return NO;
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.supportArgumentBuffers = YES;
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> state = [_device newSamplerStateWithDescriptor:sampler];
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new];
    arguments.maxBufferBindCount = 2;
    arguments.maxTextureBindCount = 1;
    arguments.maxSamplerStateBindCount = 1;
    arguments.initializeBindings = YES;
    id<MTL4ArgumentTable> table =
        [_device newArgumentTableWithDescriptor:arguments error:error];
    if (!state || !table) {
        return imgui_error(error, @"Could not allocate ImGui bindings");
    }
    _sampler = state;
    _arguments = table;
    _pipeline = pipeline;
    return YES;
}

- (BOOL)newFrameWithError:(NSError **)error
{
    if (!_context || _context != ImGui::GetCurrentContext()) {
        return imgui_error(error, @"Wrong ImGui context for Metal 4");
    }
    if (_fontTexture) {
        return YES;
    }
    unsigned char *pixels;
    int width, height;
    ImGuiIO &io = ImGui::GetIO();
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
    if (!pixels || width <= 0 || height <= 0) {
        return imgui_error(error, @"Invalid ImGui font atlas");
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageShaderRead;
    _fontTexture = [_device newTextureWithDescriptor:descriptor];
    if (!_fontTexture) {
        return imgui_error(error, @"Could not allocate ImGui font atlas");
    }
    [_fontTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:pixels
                    bytesPerRow:(NSUInteger)width * 4];
    io.Fonts->SetTexID((ImTextureID)(uintptr_t)(__bridge void *)_fontTexture);
    return YES;
}

- (void)invalidateFonts
{
    if (!_context) {
        return;
    }
    ImGuiContext *previous = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(_context);
    ImGui::GetIO().Fonts->SetTexID(0);
    ImGui::SetCurrentContext(previous);
    _fontTexture = nil;
}

- (void)shutdown
{
    if (!_context) {
        return;
    }
    ImGuiContext *previous = ImGui::GetCurrentContext();
    ImGui::SetCurrentContext(_context);
    ImGuiIO &io = ImGui::GetIO();
    if (io.BackendRendererUserData == (__bridge void *)self) {
        [self invalidateFonts];
        io.BackendRendererUserData = nullptr;
        io.BackendRendererName = nullptr;
        io.BackendFlags &= ~ImGuiBackendFlags_RendererHasVtxOffset;
    }
    ImGui::SetCurrentContext(previous);
    _context = nullptr;
}

- (void)setupEncoder:(id<MTL4RenderCommandEncoder>)encoder
               width:(NSUInteger)width
              height:(NSUInteger)height
{
    [encoder setRenderPipelineState:_pipeline];
    [encoder
        setViewport:MTLViewport{ 0, 0, (double)width, (double)height, 0, 1 }];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setTriangleFillMode:MTLTriangleFillModeFill];
    [encoder setArgumentTable:_arguments
                     atStages:MTLRenderStageVertex | MTLRenderStageFragment];
}

- (BOOL)encodeDrawData:(const ImDrawData *)drawData
              commands:(NV2AMetalCommands *)commands
                target:(id<MTLTexture>)target
                 error:(NSError **)error
{
    return [self encodeDrawData:drawData commands:commands target:target
                           clear:NO error:error];
}

- (BOOL)encodeDrawData:(const ImDrawData *)drawData
              commands:(NV2AMetalCommands *)commands
                target:(id<MTLTexture>)target
                 clear:(BOOL)clear
                 error:(NSError **)error
{
    if (!_context || _context != ImGui::GetCurrentContext() || !drawData ||
        commands.device != _device || !commands.commandBuffer ||
        target.device != _device || target.pixelFormat != _pixelFormat ||
        target.textureType != MTLTextureType2D || target.sampleCount != 1 ||
        !(target.usage & MTLTextureUsageRenderTarget)) {
        return imgui_error(error, @"Invalid Metal 4 ImGui render state");
    }
    float width = drawData->DisplaySize.x * drawData->FramebufferScale.x;
    float height = drawData->DisplaySize.y * drawData->FramebufferScale.y;
    if (!std::isfinite(width) || !std::isfinite(height) ||
        !std::isfinite(drawData->DisplayPos.x) ||
        !std::isfinite(drawData->DisplayPos.y)) {
        return imgui_error(error, @"Invalid ImGui viewport");
    }
    BOOL hasDraws = width >= 1 && height >= 1 && drawData->CmdListsCount != 0;
    if (!hasDraws && !clear) {
        return YES;
    }
    if (hasDraws && (drawData->DisplaySize.x <= 0 ||
                     drawData->DisplaySize.y <= 0 || width > target.width ||
                     height > target.height)) {
        return imgui_error(error, @"ImGui viewport exceeds its Metal target");
    }
    int listCount = hasDraws ? drawData->CmdListsCount : 0;
    /* Backend-owned vertex/index data and projection are immutable CPU
     * uploads. Only fragment textures/attachments depend on prior GPU work.
     * Opaque callbacks may encode their own vertex work; keep their original
     * entry/exit scope. ResetRenderState only restores our own bindings. */
    MTLStages stages = MTLStageFragment;
    BOOL needsPipeline = NO;
    for (int i = 0; i < listCount; i++) {
        const ImDrawList *list = drawData->CmdLists[i];
        if (!list->VtxBuffer.Size || !list->IdxBuffer.Size) {
            continue;
        }
        for (const ImDrawCmd &draw : list->CmdBuffer) {
            if (draw.UserCallback) {
                if (draw.UserCallback != ImDrawCallback_ResetRenderState) {
                    stages |= MTLStageVertex;
                }
            } else if (draw.ElemCount) {
                needsPipeline = YES;
            }
        }
        if (needsPipeline && (stages & MTLStageVertex)) {
            break;
        }
    }
    if (needsPipeline && ![self prepareDrawPipelineWithError:error]) {
        return NO;
    }
    if (![commands addResource:target error:error]) {
        return NO;
    }
    if (needsPipeline) {
        float projection[] = { 2.0f / drawData->DisplaySize.x,
                               -2.0f / drawData->DisplaySize.y, 0, 0 };
        projection[2] = -1.0f - drawData->DisplayPos.x * projection[0];
        projection[3] = 1.0f - drawData->DisplayPos.y * projection[1];
        NSUInteger constantsOffset = 0;
        id<MTLBuffer> constants = [commands uploadBytes:projection
                                                 length:sizeof(projection)
                                                 offset:&constantsOffset
                                                  error:error];
        if (!constants || ![commands keepAlive:self error:error]) {
            return NO;
        }
        [_arguments setAddress:constants.gpuAddress + constantsOffset
                       atIndex:1];
        [_arguments setSamplerState:_sampler.gpuResourceID atIndex:0];
    }
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction =
        clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTL4RenderCommandEncoder> encoder =
        [commands.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        return imgui_error(error, @"Could not create ImGui render encoder");
    }
    [encoder barrierAfterQueueStages:MTLStageAll
                        beforeStages:stages
                   visibilityOptions:MTL4VisibilityOptionDevice];
    if (needsPipeline) {
        [self setupEncoder:encoder
                     width:(NSUInteger)width
                    height:(NSUInteger)height];
    }
    BOOL success = YES;
    for (int listIndex = 0; success && listIndex < listCount;
         listIndex++) {
        const ImDrawList *list = drawData->CmdLists[listIndex];
        if (list->VtxBuffer.Size == 0 || list->IdxBuffer.Size == 0) {
            continue;
        }
        NSUInteger indexBytes = 0, indexOffset = 0;
        id<MTLBuffer> indices = nil;
        BOOL uploadList = NO;
        if (needsPipeline) {
            for (const ImDrawCmd &draw : list->CmdBuffer) {
                if ((draw.UserCallback &&
                     draw.UserCallback != ImDrawCallback_ResetRenderState) ||
                    (!draw.UserCallback && draw.ElemCount)) {
                    uploadList = YES;
                    break;
                }
            }
        }
        if (uploadList) {
            NSUInteger vertexBytes = (NSUInteger)list->VtxBuffer.Size *
                                     sizeof(ImDrawVert);
            indexBytes = (NSUInteger)list->IdxBuffer.Size * sizeof(ImDrawIdx);
            NSUInteger vertexOffset;
            id<MTLBuffer> vertices = [commands uploadBytes:list->VtxBuffer.Data
                                                   length:vertexBytes
                                                   offset:&vertexOffset
                                                    error:error];
            if (vertices) {
                indices = [commands uploadBytes:list->IdxBuffer.Data
                                         length:indexBytes
                                         offset:&indexOffset
                                          error:error];
            }
            if (!indices) {
                success = NO;
                break;
            }
            [_arguments setAddress:vertices.gpuAddress + vertexOffset atIndex:0];
        }
        for (const ImDrawCmd &draw : list->CmdBuffer) {
            if (draw.UserCallback) {
                if (draw.UserCallback == ImDrawCallback_ResetRenderState) {
                    if (needsPipeline) {
                        [self setupEncoder:encoder
                                     width:(NSUInteger)width
                                    height:(NSUInteger)height];
                    }
                } else {
                    draw.UserCallback(list, &draw);
                }
                continue;
            }
            if (!draw.ElemCount) {
                continue;
            }
            if (draw.IdxOffset > (unsigned)list->IdxBuffer.Size ||
                draw.ElemCount >
                    (unsigned)list->IdxBuffer.Size - draw.IdxOffset ||
                draw.VtxOffset >= (unsigned)list->VtxBuffer.Size) {
                success = imgui_error(error, @"Invalid ImGui index range");
                break;
            }
            float x0 = (draw.ClipRect.x - drawData->DisplayPos.x) *
                       drawData->FramebufferScale.x;
            float y0 = (draw.ClipRect.y - drawData->DisplayPos.y) *
                       drawData->FramebufferScale.y;
            float x1 = (draw.ClipRect.z - drawData->DisplayPos.x) *
                       drawData->FramebufferScale.x;
            float y1 = (draw.ClipRect.w - drawData->DisplayPos.y) *
                       drawData->FramebufferScale.y;
            if (!std::isfinite(x0) || !std::isfinite(y0) ||
                !std::isfinite(x1) || !std::isfinite(y1)) {
                success = imgui_error(error, @"Invalid ImGui clip rectangle");
                break;
            }
            x0 = fmaxf(x0, 0);
            y0 = fmaxf(y0, 0);
            x1 = fminf(x1, width);
            y1 = fminf(y1, height);
            if (x1 <= x0 || y1 <= y0 || (NSUInteger)x1 <= (NSUInteger)x0 ||
                (NSUInteger)y1 <= (NSUInteger)y0) {
                continue;
            }
            id<MTLTexture> texture =
                (__bridge id<MTLTexture>)(void *)(uintptr_t)draw.GetTexID();
            if (!texture || texture.device != _device ||
                nv2a_metal_textures_alias(texture, target) ||
                texture.textureType != MTLTextureType2D ||
                texture.sampleCount != 1 ||
                !(texture.usage & MTLTextureUsageShaderRead)) {
                success = imgui_error(error, @"Invalid ImGui Metal texture");
                break;
            }
            if (![commands addResource:texture error:error]) {
                success = NO;
                break;
            }
            [_arguments setTexture:texture.gpuResourceID atIndex:0];
            [encoder setScissorRect:MTLScissorRect{
                                        (NSUInteger)x0, (NSUInteger)y0,
                                        (NSUInteger)x1 - (NSUInteger)x0,
                                        (NSUInteger)y1 - (NSUInteger)y0 }];
            [encoder
                setArgumentTable:_arguments
                        atStages:MTLRenderStageVertex | MTLRenderStageFragment];
            NSUInteger offset = (NSUInteger)draw.IdxOffset * sizeof(ImDrawIdx);
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:draw.ElemCount
                                 indexType:sizeof(ImDrawIdx) == 2 ?
                                               MTLIndexTypeUInt16 :
                                               MTLIndexTypeUInt32
                               indexBuffer:indices.gpuAddress + indexOffset +
                                           offset
                         indexBufferLength:indexBytes - offset
                             instanceCount:1
                                baseVertex:draw.VtxOffset
                              baseInstance:0];
        }
    }
    [encoder barrierAfterStages:stages
              beforeQueueStages:MTLStageAll
              visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
    return success;
}

@end
