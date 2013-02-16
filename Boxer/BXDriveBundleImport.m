/* 
 Copyright (c) 2013 Alun Bestor and contributors. All rights reserved.
 This source file is released under the GNU General Public License 2.0. A full copy of this license
 can be found in this XCode project at Resources/English.lproj/BoxerHelp/pages/legalese.html, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */


#import "BXDriveBundleImport.h"
#import "BXSimpleDriveImport.h"
#import "ADBBinCueImage.h"
#import "BXDrive.h"
#import "RegexKitLite.h"
#import "NSWorkspace+ADBFileTypes.h"


NSString * const BXDriveBundleErrorDomain = @"BXDriveBundleErrorDomain";



@implementation BXDriveBundleImport
@synthesize drive = _drive;
@synthesize destinationFolder = _destinationFolder;


#pragma mark -
#pragma mark Helper class methods

+ (BOOL) driveUnavailableDuringImport
{
    return NO;
}

+ (NSString *) nameForDrive: (BXDrive *)drive
{
	NSString *importedName = nil;
	
	importedName = drive.path.lastPathComponent.stringByDeletingPathExtension;
	
	//If the drive has a letter, then prepend it in our standard format
	if (drive.letter) importedName = [NSString stringWithFormat: @"%@ %@", drive.letter, importedName];
	
	importedName = [importedName stringByAppendingPathExtension: @"cdmedia"];
	
	return importedName;
}

+ (BOOL) isSuitableForDrive: (BXDrive *)drive
{
	NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
	
	NSSet *cueTypes = [NSSet setWithObject: @"com.goldenhawk.cdrwin-cuesheet"];
	
    //If OS X thinks the file's extension makes it a valid CUE file, treat it as a match.
	if ([workspace file: drive.path matchesTypes: cueTypes]) return YES;
    
    //If the file can be parsed as a CUE, treat it as a match too (catches renamed GOG images.)
    if ([ADBBinCueImage isCueAtPath: drive.path error: nil]) return YES;

	return NO;
}

#pragma mark -
#pragma mark Initialization and deallocation

- (id <BXDriveImport>) initForDrive: (BXDrive *)drive
					  toDestination: (NSString *)destinationFolder
						  copyFiles: (BOOL)copy;
{
	if ((self = [super init]))
	{
        self.drive = drive;
        self.destinationFolder = destinationFolder;
        self.copyFiles = copy;
	}
	return self;
}

- (void) dealloc
{
    self.drive = nil;
    self.destinationFolder = nil;
    
	[super dealloc];
}

- (NSString *) importedDrivePath
{
    if (!self.drive || !self.destinationFolder) return nil;
    
	NSString *driveName			= [self.class nameForDrive: self.drive];
	NSString *destinationPath	= [self.destinationFolder stringByAppendingPathComponent: driveName];
    
    return destinationPath;
}

#pragma mark -
#pragma mark The actual operation, finally


- (BOOL) shouldPerformOperation
{
    return [super shouldPerformOperation] && self.drive && self.destinationFolder;
}

- (void) performOperation
{	
	NSString *sourcePath		= self.drive.path;
	NSString *destinationPath	= self.importedDrivePath;
	
	NSError *readError = nil;
	NSString *cueContents = [[[NSString alloc] initWithContentsOfFile: sourcePath
                                                         usedEncoding: NULL
                                                                error: &readError] autorelease];
    
	if (!cueContents)
	{
		self.error = readError;
		return;
	}
	
	NSArray *relatedPaths		= [ADBBinCueImage rawPathsInCueContents: cueContents];
	NSUInteger numRelatedPaths	= relatedPaths.count;
	
    
    //Bail out if we aren't able to parse the source files from this cue.
    if (!numRelatedPaths)
    {
        NSError *cueParseError = [BXDriveBundleCueParseError errorWithDrive: self.drive];
        [self setError: cueParseError];
        return;
    }
    
	if (self.isCancelled) return;
    
    //Work out what to do with the related file paths we've parsed from the cue file
    NSString *sourceBasePath = [sourcePath stringByDeletingLastPathComponent];
    NSMutableDictionary *revisedPaths = [NSMutableDictionary dictionaryWithCapacity: numRelatedPaths];
    
    for (NSString *fromPath in relatedPaths)
    {
        //Rewrite Windows-style paths
        NSString *sanitisedFromPath = [fromPath stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
        
        NSString *fullFromPath	= [sourceBasePath stringByAppendingPathComponent: sanitisedFromPath].stringByStandardizingPath;
        NSString *fromName		= fullFromPath.lastPathComponent;
        NSString *fullToPath	= [destinationPath stringByAppendingPathComponent: fromName];
        
        [self addTransferFromPath: fullFromPath toPath: fullToPath];
        
        //Make a note of the path if it needs to be changed when we rewrite the CUE file
        //(e.g. if it's in a subdirectory that will no longer exist when the files are imported)
        if (![fromPath isEqualToString: fromName])
            [revisedPaths setObject: fromName forKey: fromPath];
    }
    
    if (self.isCancelled) return;
    
    //Perform the standard file import
    _hasWrittenFiles = NO;
    [super performOperation];
    _hasWrittenFiles = YES;
    
    if (!self.error)
    {
        //Once the transfer's finished, generate a revised cue file and write it to the new bundle
        NSMutableString *revisedCue = [cueContents mutableCopy];
        for (NSString *oldPath in revisedPaths.keyEnumerator)
        {
            NSString *newPath = [revisedPaths objectForKey: oldPath];
            //FIXME: this could break the CUE file if an old filename is exactly
            //the same as a standard CUE keyword. Which is never going to happen,
            //but we really should track the ranges of each path as well.
            [revisedCue replaceOccurrencesOfString: oldPath
                                        withString: newPath
                                           options: NSLiteralSearch
                                             range: NSMakeRange(0, revisedCue.length)];
        }
        
        NSString *finalCuePath = [destinationPath stringByAppendingPathComponent: @"tracks.cue"];
        
        NSError *cueError = nil;
        BOOL cueWritten = [revisedCue writeToFile: finalCuePath
                                       atomically: YES
                                         encoding: NSUTF8StringEncoding
                                            error: &cueError];
        [revisedCue release];
        
        if (!cueWritten)
        {
            self.error = cueError;
        }
        else if (!self.copyFiles)
        {
            //If we were moving rather than copying, then delete the original
            //cue file once we've written the new one
            NSFileManager *manager = [[NSFileManager alloc] init];
            [manager removeItemAtPath: sourcePath error: nil];
            [manager release];
        }
    }
    
    //If the import failed for any reason (including cancellation),
    //then clean up the partial files.
    if (self.error) [self undoTransfer];
}


- (BOOL) undoTransfer
{
	BOOL undid = [super undoTransfer];
    NSString *destinationPath = self.importedDrivePath;
	if (self.copyFiles && destinationPath && _hasWrittenFiles)
	{
		NSFileManager *manager = [[NSFileManager alloc] init];
		undid = [manager removeItemAtPath: destinationPath error: nil];
        [manager release];
	}
	return undid;
}
@end


@implementation BXDriveBundleCueParseError

+ (id) errorWithDrive: (BXDrive *)drive
{
	NSString *displayName = drive.title;
	NSString *descriptionFormat = NSLocalizedString(@"The image “%1$@” could not be imported because Boxer was unable to determine its source files.",
													@"Error shown when drive bundle importing fails because the CUE file could not be parsed. %1$@ is the display title of the drive.");
	
	NSString *description	= [NSString stringWithFormat: descriptionFormat, displayName];
	NSString *suggestion	= NSLocalizedString(@"This image may be in a format that Boxer does not support.", @"Explanatory message shown when drive bundle importing fails because the CUE file could not be parsed.");
	
	NSDictionary *userInfo	= [NSDictionary dictionaryWithObjectsAndKeys:
							   description,		NSLocalizedDescriptionKey,
							   suggestion,		NSLocalizedRecoverySuggestionErrorKey,
							   drive.path,      NSFilePathErrorKey,
							   nil];
	
	return [NSError errorWithDomain: BXDriveBundleErrorDomain
                               code: BXDriveBundleCouldNotParseCue
                           userInfo: userInfo];
}
@end
