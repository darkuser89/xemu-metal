/* CPU-only Metal pipeline compiler tests; no device or GPU is created.
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "test-metal-pipeline-compiler-fake.h"
#include "test-metal-pipeline-compiler-concurrency.h"

int main(void)
{
    @autoreleasepool {
        pipeline_compiler_fake_tests();
        pipeline_compiler_concurrency_tests();
        puts("Metal pipeline compiler CPU tests passed: sequential and "
             "concurrent");
    }
    return 0;
}
