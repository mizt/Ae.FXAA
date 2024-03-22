#import "AEConfig.h"
#import "AE_Effect.h"
#import "AE_Macros.h"
#import "Param_Utils.h"

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <vector>

#import "Config.h"

namespace FileManager {
    NSString *resource(NSString *identifier, NSString *filename, NSString *ext) {
        return [[[NSBundle bundleWithIdentifier:identifier] URLForResource:filename withExtension:ext] path];
    }
    NSString *resource(NSString *identifier, NSString *filename) {
        return resource(identifier,[filename stringByDeletingPathExtension],[filename pathExtension]);
    }
    NSURL *URL(NSString *path) {
        return [NSURL fileURLWithPath:path];
    }
};

static PF_Err Render(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
    
    PF_Err err = PF_Err_NONE;

    int width  = output->width;
    int height = output->height;
    
    unsigned int *dst = (unsigned int *)output->data;
    int dstRow = output->rowbytes>>2;
    
    bool fill = true;
    
    if(width>=256&&height>=256) {
                        
        PF_LayerDef *input = &params[Params::INPUT]->u.ld;
        
        if(input->width==width&&input->height==height)  {
            
            int tid = -1;
            [MFR::lock lock];
            @try {
                
                bool create = false;
                
                if(MFR::threads.size()==0) {
                    tid = 0;
                    create = true;
                }
                else {
                    tid = -1;
                    for(int k=0; k<MFR::threads.size(); k++) {
                        if(MFR::threads[k]==false) {
                            MFR::threads[k] = true;
                            tid = k;
                            break;;
                        }
                    }
                    if(tid==-1) {
                        tid = (int)MFR::threads.size();
                        create = true;
                    }
                }
                
                if(create) {
                    MFR::threads.push_back(true);
                    MFR::queues.push_back([MTLCreateSystemDefaultDevice() newCommandQueue]);
                }
            }
            @finally {
                [MFR::lock unlock];
            }
            
            NSString *path = FileManager::resource(IDENTIFIER,METALLIB);
            
            dispatch_fd_t fd = open([path UTF8String],O_RDONLY);
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            
            long size = [[attributes objectForKey:NSFileSize] integerValue];
            if(size>0) {
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                __block id<MTLLibrary> library = nil;
                dispatch_read(fd,size,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^(dispatch_data_t d, int e) {
                    NSError *err = nil;
                    library = [MFR::queues[tid].device newLibraryWithData:d error:&err];
                    close(fd);
                    dispatch_semaphore_signal(semaphore);
                });
                dispatch_semaphore_wait(semaphore,DISPATCH_TIME_FOREVER);
                
                if(library) {
                    id<MTLBuffer> resolution = [MFR::queues[tid].device newBufferWithLength:sizeof(float)*2 options:MTLResourceCPUCacheModeDefaultCache];
                    id<MTLBuffer> x = [MFR::queues[tid].device newBufferWithLength:sizeof(float) options:MTLResourceCPUCacheModeDefaultCache];
                    id<MTLBuffer> y = [MFR::queues[tid].device newBufferWithLength:sizeof(float) options:MTLResourceCPUCacheModeDefaultCache];
                    
                    int w = ((width+7)>>3)<<3;
                    int h = ((height+7)>>3)<<3;
                    
                    id<MTLTexture> texture[2] = {nil,nil};
                    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
                    desc.usage = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
                    
                    texture[0] = [MFR::queues[tid].device newTextureWithDescriptor:desc];
                    texture[1] = [MFR::queues[tid].device newTextureWithDescriptor:desc];
                    
                    float *res = (float *)[resolution contents];
                    res[0] = w;
                    res[1] = h;
                    
                    unsigned int *data = new unsigned int[w*h];
                    for(int k=0; k<w*h; k++) data[k] = 0xFF808080;
                    
                    unsigned int *src = (unsigned int *)input->data;
                    int srcRow = input->rowbytes>>2;

                    for(int i=0; i<height; i++) {
                        for(int j=0; j<width; j++) {
                            data[i*w+j] = 0xFF000000|(src[i*srcRow+j]>>8);
                        }
                    }
                    
                    [texture[0] replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:data bytesPerRow:w<<2];
                                        
                    NSError *err = nil;
                    id<MTLFunction> function = [library newFunctionWithName:@"processimage"];
                    id<MTLComputePipelineState> pipelineState = [MFR::queues[tid].device newComputePipelineStateWithFunction:function error:&err];
                    id<MTLCommandQueue> queue = [MFR::queues[tid].device newCommandQueue];
                    
                    id<MTLCommandBuffer> commandBuffer = queue.commandBuffer;
                    id<MTLComputeCommandEncoder> encoder = commandBuffer.computeCommandEncoder;
                    [encoder setComputePipelineState:pipelineState];
                    [encoder setTexture:texture[0] atIndex:0];
                    [encoder setTexture:texture[1] atIndex:1];
                    [encoder setBuffer:resolution offset:0 atIndex:0];
                    
                    int tx = 1;
                    int ty = 1;
                    for(int k=1; k<5; k++) {
                        if(w%(1<<k)==0) tx = 1<<k;
                        if(h%(1<<k)==0) ty = 1<<k;
                    }
                    MTLSize threadGroupSize = MTLSizeMake(tx,ty,1);
                    MTLSize threadGroups = MTLSizeMake(w/tx,h/ty,1);
                    
                    [encoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadGroupSize];
                    [encoder endEncoding];
                    [commandBuffer commit];
                    [commandBuffer waitUntilCompleted];
                    
                    [texture[1] getBytes:data bytesPerRow:w<<2 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
                                        
                    for(int i=0; i<height; i++) {
                        for(int j=0; j<width; j++) {
                            dst[i*dstRow+j] = 0xFF|(data[i*w+j])<<8;
                        }
                    }
                    
                    delete[] data;
                    
                    fill = false;
                }
            }
        }
    }
    
    if(fill) {
        for(int i=0; i<height; i++) {
            for(int j=0; j<width; j++) {
                dst[i*dstRow+j] = 0xFF0000FF;
            }
        }
    }
    
    return err;
}

static PF_Err GlobalSetup(PF_InData *in_data,PF_OutData *out_data,PF_ParamDef *params[],PF_LayerDef *output) {
    PF_Err 	err = PF_Err_NONE;
    out_data->my_version = PF_VERSION(2,0,0,PF_Stage_DEVELOP,0);
    out_data->out_flags = PF_OutFlag_WIDE_TIME_INPUT;
    out_data->out_flags2 = PF_OutFlag2_SUPPORTS_THREADED_RENDERING;
    return err;
}

extern "C" {
    PF_Err EffectMain(PF_Cmd cmd, PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
        PF_Err err = PF_Err_NONE;
        try {
            switch (cmd) {
                case PF_Cmd_GLOBAL_SETUP: err = GlobalSetup(in_data,out_data,params,output); break;
                case PF_Cmd_PARAMS_SETUP: err = ParamsSetup(in_data,out_data,params,output); break;
                case PF_Cmd_RENDER: {
                    @autoreleasepool {
                        err = Render(in_data,out_data,params,output); break;
                    }
                }
                default: break;
            }
        } catch(PF_Err &thrown_err) {
            err = thrown_err;
        }
        return err;
    }
}
                        