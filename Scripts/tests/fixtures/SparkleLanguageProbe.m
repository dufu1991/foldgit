// Test-only access to the pinned Sparkle parser, without starting an application.
#import <Sparkle/Sparkle.h>

@interface SUAppcast (LanguageProbe)
- (instancetype)initWithXMLData:(NSData *)data relativeToURL:(NSURL *)url
                 stateResolver:(id)resolver
       signingValidationStatus:(SPUAppcastSigningValidationStatus)status error:(NSError **)error;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 2;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        NSError *error = nil;
        SUAppcast *feed = [[SUAppcast alloc] initWithXMLData:data relativeToURL:nil stateResolver:nil
                                  signingValidationStatus:SPUAppcastSigningValidationStatusSucceeded error:&error];
        if (feed == nil || feed.items.count != 1 || feed.items.firstObject.itemDescription == nil) return 3;
        puts(feed.items.firstObject.itemDescription.UTF8String);
    }
    return 0;
}
