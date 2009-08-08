#import <Foundation/Foundation.h>

typedef struct {
    /* The dictionary of objects for base, local, and remote */
    NSMutableDictionary *base;
    NSMutableDictionary *local;
    NSMutableDictionary *remote;
    
    /* The erged object dictionary */
    NSMutableDictionary *merged;
    
    BOOL interactive;
} Context;

static Context ctx;

@interface NSArray (xcodediff)

- (id)firstObject;

@end

@implementation NSArray (xcodediff)

- (id)firstObject
{
    return (self.count ? [self objectAtIndex:0] : nil);
}

@end


@interface NSDictionary (xcodediff)

- (NSArray *)objectsForKeys:(id <NSFastEnumeration>)keys notFoundMarker:(id)marker;

@end

@implementation NSDictionary (xcodediff)

- (NSArray *)objectsForKeys:(id <NSFastEnumeration>)keys notFoundMarker:(id)marker
{
    NSMutableArray *array = [NSMutableArray array];
    
    for (id key in keys) {
        id res = [self objectForKey:key];
        if (res || marker) {
            [array addObject:res ?: marker];
        }
    }
    
    return array;
}

@end

NSArray *uuid_keys_for_isa(NSString *isa)
{
    NSDictionary *dictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSArray arrayWithObjects:@"fileRef", nil], @"PBXBuildFile", 
                                [NSArray arrayWithObjects:@"containerPortal", nil], @"PBXContainerItemProxy", 
                                [NSArray arrayWithObjects:@"files", nil], @"PBXCopyFilesBuildPhase", 
                                [NSArray arrayWithObjects:@"files", nil], @"PBXFrameworksBuildPhase", 
                                [NSArray arrayWithObjects:@"files", nil], @"PBXResourcesBuildPhase", 
                                [NSArray arrayWithObjects:@"children", nil], @"PBXGroup", 
                                [NSArray arrayWithObjects:@"buildConfigurationList", @"buildPhases", @"buildRules", @"dependencies", @"productReference", nil], @"PBXNativeTarget", 
                                [NSArray arrayWithObjects:@"buildConfigurationList", @"mainGroup", @"targets", nil], @"PBXProject", 
                                [NSArray arrayWithObjects:@"files", nil], @"PBXShellScriptBuildPhase", 
                                [NSArray arrayWithObjects:@"files", nil], @"PBXSourcesBuildPhase", 
                                [NSArray arrayWithObjects:@"target", @"targetProxy", nil], @"PBXTargetDependency", 
                                [NSArray arrayWithObjects:@"children", nil], @"PBXVariantGroup", 
                                [NSArray arrayWithObjects:@"buildConfigurations", nil], @"XCConfigurationList", nil];
    
    return [dictionary objectForKey:isa];
}

id merge_conflict(NSString *key, id base, id local, id remote, id context, BOOL *fail)
{
    /* Conflicts fail the merge if the user has no input. */
    if (!ctx.interactive) return nil;
    
    printf("Merge conflict on key: %s base: %s\n", [[key description] UTF8String], [[base description] UTF8String]);
    printf("Left: %s\nRight: %s\n", [[local description] UTF8String], [[remote description] UTF8String]);
    
    char res = '\0';
    
    for (;;) {
        printf("Choose (l) left, (r) right, (c) context, (a) abort: ");
        fflush(stdin);
        if (fscanf(stdin, "%c", &res) == 1) {
            if (tolower(res) == 'l') {
                return local;
            } else if (tolower(res) == 'r') {
                return remote;
            } else if (tolower(res) == 'a') {
                *fail = YES;
                break;
            } else if (tolower(res) == 'c') {
                printf("\n%s\n", [[context description] UTF8String]);
            }
        }
    }
    
    return nil;
}

id element_merge3(NSString *key, id base, id local, id remote, id context, BOOL *fail);
NSArray *merge_array_preserving_order3(NSArray *base, NSArray *local, NSArray *remote);

NSArray *array_merge3(NSArray *base, NSArray *local, NSArray *remote, BOOL *fail)
{
    NSMutableArray *merged = [NSMutableArray array];

    /* The resulting array preserves order and is uniqued. */
    NSArray *allItems = merge_array_preserving_order3(base, local, remote);
    
    for (id item in allItems) {
        id bItem = [base containsObject:item] ? item : nil;
        id lItem = [local containsObject:item] ? item : nil;
        id rItem = [remote containsObject:item] ? item : nil;
        
        id result = element_merge3(nil, bItem, lItem, rItem, nil, fail);
        if (result) {
            [merged addObject:result];
        }
        
        if (*fail) break;
    }
    
    return merged;    
}

NSArray *merge_array_preserving_order2(NSArray *left, NSArray *right)
{
    NSMutableArray *merged = [NSMutableArray arrayWithArray:left];
    NSMutableArray *buffer = [NSMutableArray array];
    
    NSInteger lastIndex = 0;
    for (id object in right) {
        NSInteger index = [merged indexOfObject:object];
        
        if (index == NSNotFound) {
            [buffer addObject:object];
        } else {
            if (buffer.count) {
                for (id obj in buffer) {
                    [merged insertObject:obj atIndex:index++];
                }
                [buffer removeAllObjects];
            }
            
            lastIndex = index + 1;
        }
    }
    
    if (buffer.count) {
        for (id obj in buffer) {
            [merged insertObject:obj atIndex:lastIndex++];
        }
        [buffer removeAllObjects];
    }
    
    return merged;
}

NSArray *merge_array_preserving_order3(NSArray *base, NSArray *local, NSArray *remote)
{
    return merge_array_preserving_order2(merge_array_preserving_order2(base, local), remote);
}

NSArray *group_array_merge3(NSArray *base, NSArray *local, NSArray *remote, BOOL *fail)
{
    NSArray *allItems = array_merge3(base, local, remote, fail);
    if (*fail) return nil;
    
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableArray *objectIdentifiers = [NSMutableArray array];
    NSMutableDictionary *namesToIdentifiers = [NSMutableDictionary dictionary];
    
    /* Each of these array items is a identifier for either a group or a file. We examine
     * these items to determine a unique set of names. (It is unlikely that a project would have 
     * more than one item (of the same type) in a group with the same name.) If we find two (or more?) 
     * groups with the same name, we merge them together and use that merged group. */
     
    /* The task is to 
     *		a) for each of the items, find the associated group/file object.
     * 		b) for each object, merge the name.
     * 		c) group these names by type and unique.
     * 		c) */
    for (id item in allItems) {
        /* a) for each of the items, find the associated group/file object.
         * b) for each object, merge the name.*/
        id mergedObject = [ctx.merged objectForKey:item];
        if (!mergedObject) {
            mergedObject = element_merge3(nil, [ctx.base objectForKey:item], [ctx.local objectForKey:item], 
                                          [ctx.remote objectForKey:item], nil, fail);
        }
        if (*fail) return nil;
        if (!mergedObject) continue;
        
        /* Keep track of this object and associated identifier */
        [objects addObject:mergedObject];
        [objectIdentifiers addObject:item];
        
        /* c) group these names by type and unique. */
        NSString *name;
        NSString *type = [mergedObject objectForKey:@"isa"];
        name = [mergedObject objectForKey:@"path"];
        if (!name) {
            name = [mergedObject objectForKey:@"name"];
        }
                
        NSString *key = [NSString stringWithFormat:@"%@%@", name, type];
        
        NSMutableSet *identifiers = [namesToIdentifiers objectForKey:key];
        if (!identifiers) {
            identifiers = [NSMutableSet set];
            [namesToIdentifiers setObject:identifiers forKey:key];
        }
        
        [identifiers addObject:item];
    }
    
    /* For each merged object, we now check for duplicates and merge them together */
    NSDictionary *identifierToObject = [NSDictionary dictionaryWithObjects:objects forKeys:objectIdentifiers];
    for (NSString *identifier in objectIdentifiers) {
        NSDictionary *item = [identifierToObject objectForKey:identifier];
        
        NSString *name;
        NSString *type = [item objectForKey:@"isa"];
        name = [item objectForKey:@"path"];
        if (!name) {
            name = [item objectForKey:@"name"];
        }
        
        
        
        NSString *key = [NSString stringWithFormat:@"%@%@", name, type];
        
        NSSet *identifiers = [namesToIdentifiers objectForKey:key];
        if (identifiers.count) {
            if ([name isEqualToString:@"App"]) {
                NSLog(@"merged an App!");
            }
            
            /* If we've already merged for these identifiers, we're done */
            id mergedMember = [[ctx.merged objectsForKeys:[identifiers allObjects] notFoundMarker:nil] firstObject];
            if (mergedMember && [mergedMember objectForKey:@"__merged"]) continue;
            
            /* Find the candidate members */
            id baseMember = [[ctx.base objectsForKeys:[identifiers allObjects] notFoundMarker:nil] firstObject];
            id localMember = [[ctx.local objectsForKeys:[identifiers allObjects] notFoundMarker:nil] firstObject];
            id remoteMember = [[ctx.remote objectsForKeys:[identifiers allObjects] notFoundMarker:nil] firstObject];
            
            /* Get some merging action on */
            id result = element_merge3(identifier, baseMember, localMember, remoteMember, nil, fail);
            if (*fail) return nil;
            
            if ([name isEqualToString:@"App"]) {
                NSLog(@"merged an App!");
            }
            
            [result setObject:(id)kCFBooleanTrue forKey:@"__merged"];
            [ctx.merged setObject:result forKey:identifier];
            
            /* Now we have to nuke the other objects with this identifier so that we don't
             * try to include them again */
            NSArray *otherIdentifiers = [[identifiers allObjects] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self != %@", identifier]];
            [ctx.base removeObjectsForKeys:otherIdentifiers];
            [ctx.local removeObjectsForKeys:otherIdentifiers];
            [ctx.remote removeObjectsForKeys:otherIdentifiers];
        }
    }
    
    return objectIdentifiers;
}

NSArray *files_array_merge3(NSArray *base, NSArray *local, NSArray *remote, BOOL *fail)
{
    return array_merge3(base, local, remote, fail);
}

NSDictionary *dictionary_merge3(NSDictionary *base, NSDictionary *local, NSDictionary *remote, BOOL *fail)
{
    /* A real merge! Gather all keys and perform a recursive merge. */
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSMutableSet *allKeys = [NSMutableSet set];
    [allKeys addObjectsFromArray:[base allKeys]];
    [allKeys addObjectsFromArray:[local allKeys]];
    [allKeys addObjectsFromArray:[remote allKeys]];
    
    NSString *isa = [(base ?: (local ?: remote)) objectForKey:@"isa"];
    BOOL isGroup = [isa hasSuffix:@"Group"] || [isa isEqualToString:@"PBXResourcesBuildPhase"];
    
    for (NSString *key in allKeys) {
        id bValue = [base objectForKey:key];
        id lValue = [local objectForKey:key];
        id rValue = [remote objectForKey:key];
        
        id result;
        
        if (isGroup && [key isEqualToString:@"children"]) {
            result = group_array_merge3(bValue, lValue, rValue, fail);
        } else if (isGroup && [key isEqualToString:@"files"]) {
            result = files_array_merge3(bValue, lValue, rValue, fail);
        } else {
            result = element_merge3(key, bValue, lValue, rValue, (base ?: (local ?: remote)), fail);
        }
        
        if (result) {
            [merged setObject:result forKey:key];
        }
        
        if (*fail) break;
    }
    
    return merged;
}


id element_merge3(NSString *key, id base, id local, id remote, id context, BOOL *fail)
{
    *fail = NO;
    
    id result = nil;
    
    if (base && !(local || remote)) {
        /* The entry exists in base, but neither remote or local (deleted) */
        result = nil;
    } else if (!base && (local || remote) && !(local && remote)) {
        /* Added on one side only */
        result = (local ?: remote);
    } else if (base && (local || remote) && !(local && remote)) {
        /* Existed in the base, and currently on one side, but not the other. 
         * If the element in local or remote is equal to the one on the base, delete it.
         * If it has changed, ask the user which to keep */
        if ([base isEqual:(local ?: remote)]) {
            result = nil;
        } else {
            result = merge_conflict(key, base, local, remote, context, fail);
        }
    } else if (local && remote) {
        /* Two separate changes (potentially) */
        /* Something is different! */
        if ([local isKindOfClass:[NSArray class]]) {
            return array_merge3(base, local, remote, fail);
        } else if ([local isKindOfClass:[NSDictionary class]]) {
            return dictionary_merge3(base, local, remote, fail);
        } else if ([local isEqual:remote]) {
            /* Identical! */
            return local;            
        } else {
            /* Merge conflict */
            return merge_conflict(key, base, local, remote, context, fail);
        }
    }
    
    return result;
}

BOOL objects_merge3(NSDictionary *base, NSDictionary *local, NSDictionary *remote)
{
    /* First, get aggregate set of keys */
    NSMutableSet *allKeys = [NSMutableSet set];
    [allKeys addObjectsFromArray:[base allKeys]];
    [allKeys addObjectsFromArray:[local allKeys]];
    [allKeys addObjectsFromArray:[remote allKeys]];
    
    /* Iterate over all keys */
    for (NSString *key in allKeys) {
        /* The object could already be merged in -- this can happen
         * with duplicate groups. The object will be force merged in by the 
         * group_merge method above */
        if ([ctx.merged objectForKey:key]) continue;
        
        BOOL fail = NO;
        NSDictionary *result = element_merge3(key, [base objectForKey:key], [local objectForKey:key], [remote objectForKey:key], nil, &fail);
        
        /* If we didn't resolve a conflict */
        if (fail) return NO;
        
        if (result) {
            /* Merge in new entries */
            [ctx.merged setObject:result forKey:key];
        }
    }
    
    return YES;
}

id project_file_merge3(NSDictionary *base, NSDictionary *local, NSDictionary *remote)
{
    ctx.base = [base objectForKey:@"objects"];
    ctx.local = [local objectForKey:@"objects"];
    ctx.remote = [remote objectForKey:@"objects"];
    ctx.merged = [NSMutableDictionary dictionary];
    
    NSMutableDictionary *document = [NSMutableDictionary dictionaryWithDictionary:base];
    
    /* Merge elements */
    if (!objects_merge3(ctx.base, ctx.local, ctx.remote)) return nil;

    /* Put the elements in our document */
    [document setObject:ctx.merged forKey:@"objects"];
    
    /* Find project element and enforce root object */
    NSDictionary *project = [[[ctx.merged allValues] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"isa = %@", @"PBXProject"]] objectAtIndex:0];
    [document setObject:[[ctx.merged allKeysForObject:project] objectAtIndex:0] forKey:@"rootObject"];
    
    return document;
}

void serialize_element(id element, NSMutableString *string, NSUInteger level)
{
    if ([element isKindOfClass:[NSArray class]]) {
        NSString *levelString = [@"" stringByPaddingToLength:level + 1 withString:@"\t" startingAtIndex:0];
        [string appendString:@"(\n"];
        for (id item in element) {
            [string appendString:levelString];
            serialize_element(item, string, level + 1);
            [string appendString:@",\n"];
        }
        [string appendFormat:@"%@)", [@"" stringByPaddingToLength:level withString:@"\t" startingAtIndex:0]];
    } else if ([element isKindOfClass:[NSDictionary class]]) {
        NSString *levelString = [@"" stringByPaddingToLength:level + 1 withString:@"\t" startingAtIndex:0];
        [string appendString:@"{\n"];
        for (id key in [(NSDictionary *)element allKeys]) {
            [string appendFormat:@"%@%@ = ", levelString, key];
            serialize_element([(NSDictionary *)element objectForKey:key], string, level + 1);
            [string appendString:@";\n"];
        }
        [string appendFormat:@"%@}", [@"" stringByPaddingToLength:level withString:@"\t" startingAtIndex:0]];
    } else if ([element isKindOfClass:[NSString class]]) {
        /* Escape string */
        NSMutableString *escapedString = [[element mutableCopy] autorelease];
        NSArray *escapableCharacters = [NSArray arrayWithObjects:@"\n", @"\"", @"\t", nil];
        NSArray *escapes = [NSArray arrayWithObjects:@"\\n", @"\\\"", @"\\t", nil];
        for (NSUInteger i = 0; i < [escapableCharacters count]; i++) {
            [escapedString replaceOccurrencesOfString:[escapableCharacters objectAtIndex:i] withString:[escapes objectAtIndex:i] options:0 range:NSMakeRange(0,[escapedString length])];
        }
        
        if ([escapedString rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" -<>(){}+?"]].length != 0 ||
            [escapedString length] == 0) {
            [string appendFormat:@"\"%@\"", escapedString];
        } else {
            [string appendString:escapedString];
        }
    } else {
        [string appendString:[element description]];
    }
}

NSData *serialize_ascii_plist(NSDictionary *base)
{
    NSMutableString *string = [NSMutableString string];
    [string appendString:@"// !$*UTF8*$!\n"];
    
    serialize_element(base, string, 0);
    
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

#if 0

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSArray *left = [@"a,b,c,d" componentsSeparatedByString:@","];
    NSArray *right = [@"a,e,f,b,c,g,h,i" componentsSeparatedByString:@","];
    
    NSLog(@"\nleft: %@\nright: %@\nresult: %@", left, right, merge_array_preserving_order2(left, right));
    
    left = nil;
    right = [@"a,b,c,d" componentsSeparatedByString:@","];
    
    NSLog(@"\nleft: %@\nright: %@\nresult: %@", left, right, merge_array_preserving_order2(left, right));
    
    [pool drain];
    return 0;
}
    

#elif 0

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    NSString *error;
    NSDictionary *dict = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:@"/project.LOCAL.pbxproj"] 
                                                          mutabilityOption:NSPropertyListImmutable 
                                                                    format:NULL 
                                                          errorDescription:&error];
    NSLog(@"first: %@", error);
    
    /* Write the merged data */
    NSData *data = serialize_ascii_plist(dict);
    
    [data writeToFile:@"/Volumes/CC/Things mac/Things.xcodeproj/project.pbxproj" atomically:YES];
    
    
    
    dict = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:@"/Volumes/CC/Things mac/Things.xcodeproj/project.pbxproj"] 
                                                          mutabilityOption:NSPropertyListImmutable 
                                                                    format:NULL 
                                                          errorDescription:&error];
    
    NSLog(@"%@", error);
    
    [pool drain];
    return 0;
}

#else

int main (int argc, const char * argv[]) {
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    /* Input is %O %A %B %M. %O is the base, %A is the left and %B is the right. 
     * We are expected to overwrite A with the results, unless %M is defined, in
     * which case we write the results to %M. */
    
    if (argc <= 3) {
        printf("Usage: xcode-diff <base> <local> <remote> [<merge>]\n");
        exit(1);
    }
    
    if (strcmp(argv[1], "-i") == 0) {
        ctx.interactive = YES;
        argv++;
    }
    
    /* Load dictionaries */
    NSDictionary *dicts[3];
    for (NSUInteger i = 0; i < 3; i++) {
        NSString *path = [NSString stringWithUTF8String:argv[i + 1]];
        dicts[i] = [NSPropertyListSerialization propertyListFromData:[NSData dataWithContentsOfFile:path] 
                                                    mutabilityOption:NSPropertyListMutableContainers
                                                              format:NULL 
                                                    errorDescription:NULL];
    }
    
    
    /* Do the merge, exiting with a status code of 1 on failure */
    id result = project_file_merge3(dicts[0], dicts[1], dicts[2]);
    
    if (!result) return 1;
    
    /* Write the merged data */
    NSData *data = serialize_ascii_plist(result);
    
    NSString *destination = [NSString stringWithUTF8String:(argc > 4 ? argv[4] : argv[2])];
    [data writeToFile:destination atomically:YES];
    
    [pool drain];
    return 0;
}

#endif
