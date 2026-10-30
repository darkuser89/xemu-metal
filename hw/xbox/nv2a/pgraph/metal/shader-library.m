/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import "shader-library.h"

@interface NV2AMetalCompilerContext : NSObject
@property(nonatomic) id<MTL4Compiler> compiler;
@property(nonatomic) NSMapTable<NSValue *, NV2AMetalShaderLibrary *> *modules;
/* Counts actual library requests, including failures; read only under lock. */
@property(nonatomic) NSUInteger libraryBuildCount;
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error;
@end
@implementation NV2AMetalCompilerContext
- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error
{
    self = [super init];
    if (!self)
        return nil;
    _compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new]
                                            error:error];
    if (!_compiler)
        return nil;
    _modules = [NSMapTable strongToWeakObjectsMapTable];
    return self;
}
@end

@interface NV2AMetalShaderLibrary ()
- (instancetype)initWithContext:(NV2AMetalCompilerContext *)context
                        library:(id<MTLLibrary>)library;
@end
@implementation NV2AMetalShaderLibrary {
    NV2AMetalCompilerContext *_context;
    NSMutableDictionary<NSString *, id<MTLComputePipelineState>> *_compute;
    NSUInteger _computeBuildCount;
}
- (instancetype)initWithContext:(NV2AMetalCompilerContext *)context
                        library:(id<MTLLibrary>)library
{
    self = [super init];
    if (self) {
        _context = context;
        _library = library;
        _compute = [NSMutableDictionary new];
    }
    return self;
}
- (id<MTL4Compiler>)compiler
{
    return _context.compiler;
}
+ (instancetype)sharedWithDevice:(id<MTLDevice>)device
                          source:(const char *)source
                           error:(NSError **)error
{
    if (!device || !source || !source[0] || !device.hasUnifiedMemory ||
        ![device supportsFamily:MTLGPUFamilyApple7] ||
        ![device supportsFamily:MTLGPUFamilyMetal4]) {
        if (error)
            *error = [NSError
                errorWithDomain:@"xemu.nv2a.metal4.shader-library"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Shared shader library requires static source "
                               @"and Apple Silicon Metal4"
                       }];
        return nil;
    }
    static NSMapTable<id<MTLDevice>, NV2AMetalCompilerContext *> *contexts;
    NV2AMetalCompilerContext *context;
    @synchronized(NV2AMetalShaderLibrary.class) {
        if (!contexts)
            contexts = [[NSMapTable alloc]
                initWithKeyOptions:NSPointerFunctionsWeakMemory |
                                   NSPointerFunctionsObjectPointerPersonality
                      valueOptions:NSPointerFunctionsWeakMemory
                          capacity:1];
        context = [contexts objectForKey:device];
        if (!context) {
            context = [[NV2AMetalCompilerContext alloc] initWithDevice:device
                                                                 error:error];
            if (!context)
                return nil;
            [contexts setObject:context forKey:device];
        }
    }
    @synchronized(context) {
        NSValue *key = [NSValue valueWithPointer:source];
        NV2AMetalShaderLibrary *module = [context.modules objectForKey:key];
        if (!module) {
            MTL4LibraryDescriptor *descriptor = [MTL4LibraryDescriptor new];
            descriptor.source = @(source);
            descriptor.options = [MTLCompileOptions new];
            descriptor.options.languageVersion = MTLLanguageVersion4_0;
            descriptor.options.mathMode = MTLMathModeSafe;
            descriptor.options.mathFloatingPointFunctions =
                MTLMathFloatingPointFunctionsPrecise;
            id<MTLLibrary> library;
            @synchronized(context.compiler) {
                context.libraryBuildCount++;
                library = [context.compiler newLibraryWithDescriptor:descriptor
                                                               error:error];
            }
            if (!library)
                return nil;
            module = [[self alloc] initWithContext:context library:library];
            [context.modules setObject:module forKey:key];
        }
        return module;
    }
}
- (id<MTLComputePipelineState>)computeFunction:(NSString *)name
                                         error:(NSError **)error
{
    if (!name.length) {
        if (error)
            *error = [NSError errorWithDomain:@"xemu.nv2a.metal4.shader-library"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Missing compute function name"
                                     }];
        return nil;
    }
    @synchronized(self) {
        id<MTLComputePipelineState> pipeline = _compute[name];
        if (!pipeline) {
            /* Reject a missing entry before the driver resolves its function;
             * the Metal4 compute descriptor requires a nonnil function. */
            if (![_library.functionNames containsObject:name]) {
                if (error)
                    *error = [NSError
                        errorWithDomain:@"xemu.nv2a.metal4.shader-library"
                                   code:1
                               userInfo:@{
                                   NSLocalizedDescriptionKey :
                                       @"Unknown compute function name"
                               }];
                return nil;
            }
            MTL4LibraryFunctionDescriptor *function =
                [MTL4LibraryFunctionDescriptor new];
            function.library = _library;
            function.name = name;
            MTL4ComputePipelineDescriptor *descriptor =
                [MTL4ComputePipelineDescriptor new];
            descriptor.computeFunctionDescriptor = function;
            @synchronized(self.compiler) {
                _computeBuildCount++;
                pipeline = [self.compiler
                    newComputePipelineStateWithDescriptor:descriptor
                                      compilerTaskOptions:nil
                                                    error:error];
            }
            if (pipeline)
                _compute[name] = pipeline;
        }
        return pipeline;
    }
}
@end
