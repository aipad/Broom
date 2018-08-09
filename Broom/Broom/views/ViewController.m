//
//  ViewController.m
//  Broom
//
//  Created by Ben Sparkes on 08/08/2018.
//  Copyright © 2018 Ben Sparkes. All rights reserved.
//

#import "ViewController.h"

#include "amfi.h"
#include "kernel.h"
#include "offsetfinder.h"
#include "patchfinder64.h"
#include "root-rw.h"
#include "untar.h"
#include "utils.h"
#include "v0rtex.h"

#include <dlfcn.h>
#include <sys/stat.h>

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UIButton *goButton;
@property (weak, nonatomic) IBOutlet UILabel *versionLabel;
@end

@implementation ViewController

NSString *Version = @"Broom: v1.0.0 - by PsychoTea, w/ thanks to saurik";
BOOL allowedToRun = TRUE;

offsets_t *offsets;

task_t   kernel_task;
uint64_t kernel_base;
uint64_t kernel_slide;

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self.versionLabel setText:Version];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        int waitTime;
        while ((waitTime = 90 - uptime()) > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.goButton setTitle:[NSString stringWithFormat:@"wait: %ds", waitTime] forState:UIControlStateNormal];
            });
            allowedToRun = FALSE;
            sleep(1);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.goButton setTitle:@"go" forState:UIControlStateNormal];
        });
        allowedToRun = TRUE;
    });
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)goButtonPressed:(UIButton *)button {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self makeShitHappen];
    });
}

- (void)makeShitHappen {
    int ret;
    kern_return_t kret;
    
    if (allowedToRun == FALSE) return;
    
    allowedToRun = FALSE;
    [self.goButton setAlpha:0.7];
    
    [self updateStatus:@"running..."];
    
    // grab offsets via liboffsetfinder64
    offsets = get_offsets();
    
    [self updateStatus:@"grabbed offsets"];
    
    // suspend app
    suspend_all_threads();
    
    // run v0rtex
    kret = v0rtex(offsets, &v0rtex_callback, NULL);
    
    // resume app
    resume_all_threads();
    
    if (kret != KERN_SUCCESS) {
        [self updateStatus:@"v0rtex failed, rebooting..."];
        sleep(3);
        restart_device();
        return;
    }
    
    [self updateStatus:@"v0rtex success!"];
    
    // initialize kernel.m stuff
    uint64_t kernel_task_addr = rk64(offsets->kernel_task + kernel_slide);
    uint64_t kern_proc = rk64(kernel_task_addr + offsets->task_bsd_info);
    setup_kernel_tools(kernel_task, kern_proc);
    
    // initialize patchfinder64 & amfi stuff
    init_patchfinder(NULL, kernel_base);
    init_amfi();
    
    [self updateStatus:@"initialized patchfinders, etc"];
    
    // remount '/' as r/w
    NSOperatingSystemVersion osVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    int pre103 = osVersion.minorVersion < 3 ? 1 : 0;
    ret = mount_root(kernel_slide, offsets->root_vnode, pre103);
    
    if (ret != 0) {
        [self updateStatus:@"failed to remount disk0s1s1: %d", ret];
        return;
    }
    
    fclose(fopen("/.broom_test_file", "w"));
    if (access("/.broom_test_file", F_OK) != 0) {
        [self updateStatus:@"failed to remount disk0s1s1"];
        return;
    }
    unlink("/.broom_test_file");
    
    execprog("/sbin/mount", NULL);
    
    [self updateStatus:@"remounted successfully"];
    
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    
    if ([fileMgr fileExistsAtPath:@"/Applications/Eraser.app" isDirectory:NULL]) {
        [fileMgr removeItemAtPath:@"/Applications/Eraser.app" error:nil];
    }
    
    ret = extract_bundle("eraser.tar", "/Applications");
    if (ret != 0) {
        [self updateStatus:@"failed to extract eraser.tar: %d", ret];
        return;
    }
    
#define ERASER_MAIN "/Applications/Eraser.app/Eraser"
#define ERASER_LIB  "/Applications/Eraser.app/Eraser.dylib"
    
    // give +s bit & root:wheel to Eraser.app/Eraser
    inject_trust(ERASER_MAIN);
    inject_trust(ERASER_LIB);
    
    chmod(ERASER_MAIN, 6755);
    chmod(ERASER_LIB, 0755);
    
    chown(ERASER_MAIN, 0, 0);
    chown(ERASER_LIB, 0, 0);
    
    // Eraser fix
    mkdir("/var/stash", 0755);
    
    [self updateStatus:@"extracted eraser.app"];
    
    ret = mkdir("/broom", 0755);
    if (ret != 0) {
        [self updateStatus:@"failed to create the /broom directory"];
        return;
    }
    
    [self updateStatus:@"running uicache..."];
    
    ret = extract_bundle("uicache.tar", "/broom");
    if (ret != 0) {
        [self updateStatus:@"failed to extract uicache.tar: %d", ret];
        return;
    }
    
    inject_trust("/broom/uicache");
    
    execprog("/broom/uicache", NULL);
    
    [self updateStatus:@"attempting to launch app..."];
    
    // what i *could* do is modify my entitlements in memory
    // to add com.apple.springboard.launchapplications -- but
    // we want to keep this simple (KISS.). so using the binary
    // is a little more reliable/foolproof
    
    ret = extract_bundle("launchapp.tar", "/broom");
    if (ret != 0) {
        [self updateStatus:@"failed to extract launchapp.tar: %d", ret];
        return;
    }
    
    inject_trust("/broom/launchapp");
    
    execprog("/broom/launchapp", (const char **)&(const char*[]) {
        "/broom/launchapp",
        "com.saurik.Eraser",
        NULL
    });
    
    // cleanup
    [fileMgr removeItemAtPath:@"/broom" error:nil];
    
    [self updateStatus:@"done!"];
}

kern_return_t v0rtex_callback(task_t tfp0, kptr_t kbase, void *cb_data) {
    kernel_task = tfp0;
    kernel_base = kbase;
    kernel_slide = kernel_base - offsets->base;
    
    return KERN_SUCCESS;
}

- (void)updateStatus:(NSString *)text, ... {
    va_list args;
    va_start(args, text);
    
    text = [[NSString alloc] initWithFormat:text arguments:args];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.goButton setTitle:text forState:UIControlStateNormal];
    });

    NSLog(@"%@", text);

    va_end(args);
}

@end
