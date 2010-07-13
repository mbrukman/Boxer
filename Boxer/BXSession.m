/* 
 Boxer is copyright 2009 Alun Bestor and contributors.
 Boxer is released under the GNU General Public License 2.0. A full copy of this license can be
 found in this XCode project at Resources/English.lproj/GNU General Public License.txt, or read
 online at [http://www.gnu.org/licenses/gpl-2.0.txt].
 */

#import "BXSession.h"
#import "BXPackage.h"
#import "BXGameProfile.h"
#import "BXDrive.h"
#import "BXAppController.h"
#import "BXSessionWindowController+BXRenderController.h"
#import "BXSession+BXFileManager.h"
#import "BXEmulatorConfiguration.h"

#import "BXEmulator+BXDOSFileSystem.h"
#import "BXEmulator+BXShell.h"
#import "NSWorkspace+BXFileTypes.h"
#import "NSString+BXPaths.h"


//How we will store our gamebox-specific settings in user defaults.
//%@ is the unique identifier for the gamebox.
NSString * const BXGameboxSettingsKeyFormat	= @"Game Settings %@";
NSString * const BXGameboxSettingsNameKey	= @"Game Name";

#pragma mark -
#pragma mark Private method declarations

@interface BXSession ()
@property (readwrite, retain, nonatomic) NSMutableDictionary *gameSettings;
@property (readwrite, copy, nonatomic) NSString *activeProgramPath;

//Create our BXEmulator instance and starts its main loop.
//Called internally by [BXSession start], deferred to the end of the main thread's event loop to prevent
//DOSBox blocking cleanup code.
- (void) _startEmulator;

//Set up the emulator context with drive mounts and other configuration settings specific to this session.
//Called in response to the BXEmulatorWillLoadConfiguration event, once the emulator is initialised enough
//for us to configure it.
- (void) _configureEmulator;

//Start up the target program for this session (if any) and displays the program panel selector after this
//finishes. Called by runLaunchCommands, once the emulator has finished processing configuration files.
- (void) _launchTarget;

//Called once the session has exited to save any DOSBox settings we have changed to the gamebox conf.
- (void) _saveConfiguration: (BXEmulatorConfiguration *)configuration toFile: (NSString *)filePath;
@end


#pragma mark -
#pragma mark Implementation

@implementation BXSession

@synthesize mainWindowController;
@synthesize gamePackage;
@synthesize emulator;
@synthesize targetPath;
@synthesize activeProgramPath;
@synthesize gameProfile;
@synthesize gameSettings;


#pragma mark -
#pragma mark Initialization and cleanup

- (id) init
{
	if ((self = [super init]))
	{
		[self setEmulator: [[[BXEmulator alloc] init] autorelease]];
		[self setGameSettings: [NSMutableDictionary dictionaryWithCapacity: 10]];
		
	}
	return self;
}

- (void) dealloc
{
	[self setMainWindowController: nil],[mainWindowController release];
	[self setEmulator: nil],			[emulator release];
	[self setGamePackage: nil],			[gamePackage release];
	[self setGameProfile: nil],			[gameProfile release];
	[self setGameSettings: nil],		[gameSettings release];
	[self setTargetPath: nil],			[targetPath release];
	[self setActiveProgramPath: nil],	[activeProgramPath release];
		
	[super dealloc];
}

//We make this a no-op to avoid creating an NSFileWrapper - we don't ever actually read any data off disk,
//so we don't need to construct a representation of the filesystem, and trying to do so for large documents
//(e.g. root folders) can cause memory allocation crashes.
- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
	return YES;
}

- (void) makeWindowControllers
{
	id controller = [[BXSessionWindowController alloc] initWithWindowNibName: @"DOSWindow"];
	[self addWindowController:		controller];
	[self setMainWindowController:	controller];	
	[controller setShouldCloseDocument: YES];
	
	[controller release];
}

- (void) showWindows
{
	[super showWindows];
	
	//Start the emulator as soon as our windows appear
	[self start];
}

- (void) setGamePackage: (BXPackage *)package
{
	[self willChangeValueForKey: @"gamePackage"];
	
	if (package != gamePackage)
	{
		[gamePackage release];
		gamePackage = [package retain];
		
		//Also load up the settings for this gamebox
		if (gamePackage)
		{
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			NSString *defaultsKey = [NSString stringWithFormat: BXGameboxSettingsKeyFormat, [gamePackage gameIdentifier], nil];
			
			NSDictionary *gameboxSettings = [defaults objectForKey: defaultsKey];
			
			//Merge the loaded values in rather than replacing the settings altogether.
			[gameSettings addEntriesFromDictionary: gameboxSettings]; 
		}
	}
	
	[self didChangeValueForKey: @"gamePackage"];
}

- (void) setEmulator: (BXEmulator *)newEmulator
{
	[self willChangeValueForKey: @"emulator"];
	
	if (newEmulator != emulator)
	{
		if (emulator)
		{
			[emulator setDelegate: nil];
			[[emulator videoHandler] unbind: @"aspectCorrected"];
			[[emulator videoHandler] unbind: @"filterType"];
			
			[self _deregisterForFilesystemNotifications];
		}
		
		[emulator release];
		emulator = [newEmulator retain];
	
		if (newEmulator)
		{
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			
			[newEmulator setDelegate: self];
			
			//FIXME: we shouldn't be using bindings for these
			[[newEmulator videoHandler] bind: @"aspectCorrected" toObject: defaults withKeyPath: @"aspectCorrected" options: nil];
			[[newEmulator videoHandler] bind: @"filterType" toObject: defaults withKeyPath: @"filterType" options: nil];
			
			[self _registerForFilesystemNotifications];
		}
	}
	
	[self didChangeValueForKey: @"emulator"];
}

//Keep our emulator's profile and our own profile in sync
//IMPLEMENTATION NOTE: we could do this with bindings,
//but I want to avoid circular-retains and bindings hell
- (void) setGameProfile: (BXGameProfile *)profile
{
	[self willChangeValueForKey: @"gameProfile"];
	if (profile != gameProfile)
	{
		[gameProfile release];
		gameProfile = [profile retain];
		[[self emulator] setGameProfile: gameProfile];
	}
	[self didChangeValueForKey: @"gameProfile"];
}

- (BOOL) isEmulating
{
	return hasConfigured;
}

- (void) start
{
	//We schedule our internal _startEmulator method to be called separately on the main thread,
	//so that it doesn't block completion of whatever UI event led to this being called.
	//This prevents menu highlights from getting 'stuck' because of DOSBox's main loop blocking
	//the thread.
	
	if (!hasStarted) [self performSelector: @selector(_startEmulator)
								withObject: nil
								afterDelay: 0.1];
	
	//So we don't try to restart the emulator
	hasStarted = YES;
}

//Cancel the DOSBox emulator thread
- (void)cancel	{ [[self emulator] cancel]; }

//Tell the emulator to close itself down when the document closes
- (void) close
{
	if (!isClosing)
	{
		isClosing = YES;
		[self synchronizeSettings];
		[self cancel];
		[super close];
	}
}

//Save our configuration changes to disk before exiting
- (void) synchronizeSettings
{
	if ([self isGamePackage])
	{
		//Go through the settings working out which ones we should store in user defaults,
		//and which ones in the gamebox's configuration file.
		BXEmulatorConfiguration *gameboxConf = [BXEmulatorConfiguration configuration];
		
		//These are the settings we want to keep in the configuration file
		NSNumber *fixedSpeed	= [gameSettings objectForKey: @"fixedSpeed"];
		NSNumber *isAutoSpeed	= [gameSettings objectForKey: @"autoSpeed"];
		NSNumber *coreMode		= [gameSettings objectForKey: @"coreMode"];
		
		if (coreMode)
		{
			NSString *coreString = [BXEmulator configStringForCoreMode: [coreMode integerValue]];
			[gameboxConf setValue: coreString forKey: @"core" inSection: @"cpu"];
		}
		
		if (fixedSpeed || isAutoSpeed)
		{
			NSString *cyclesString = [BXEmulator configStringForFixedSpeed: [fixedSpeed integerValue]
																	isAuto: [isAutoSpeed boolValue]];
			
			[gameboxConf setValue: cyclesString forKey: @"cycles" inSection: @"cpu"];
		}
		
		//Strip out these settings once we're done, so we won't preserve them in user defaults
		[gameSettings removeObjectsForKeys: [NSArray arrayWithObjects: @"fixedSpeed", @"autoSpeed", @"coreMode", nil]];

		
		//Persist the gamebox-specific configuration into the gamebox's configuration file.
		NSString *configPath = [[self gamePackage] configurationFilePath];
		[self _saveConfiguration: gameboxConf toFile: configPath];
		
		//Save whatever's left into user defaults.
		if ([gameSettings count])
		{
			//Add the gamebox name into the settings, to make it easier to identify to which gamebox the record belongs
			[gameSettings setObject: [gamePackage gameName] forKey: BXGameboxSettingsNameKey];
			
			NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
			NSString *defaultsKey = [NSString stringWithFormat: BXGameboxSettingsKeyFormat, [[self gamePackage] gameIdentifier], nil];
			[defaults setObject: gameSettings forKey: defaultsKey];			
		}
	}
}


#pragma mark -
#pragma mark Describing the document/process

- (NSString *) displayName
{
	if ([self isGamePackage]) return [[self gamePackage] gameName];
	else return [self processDisplayName];
}

- (NSString *) processDisplayName
{
	NSString *processName = nil;
	if ([emulator isRunningProcess])
	{
		//Use the active program name where possible;
		//Failing that, fall back on the original process name
		if ([self activeProgramPath]) processName = [[self activeProgramPath] lastPathComponent];
		else processName = [emulator processName];
	}
	return processName;
}


#pragma mark -
#pragma mark Introspecting the gamebox

- (void) setFileURL: (NSURL *)fileURL
{	
	NSWorkspace *workspace	= [NSWorkspace sharedWorkspace];
	NSString *filePath		= [[fileURL path] stringByStandardizingPath];
	
	//Check if this file path is located inside a gamebox
	NSString *packagePath	= [workspace parentOfFile: filePath
										matchingTypes: [NSArray arrayWithObject: @"net.washboardabs.boxer-game-package"]];
	
	[self setTargetPath: filePath];
	
	//If the fileURL is located inside a gamebox, we use the gamebox itself as the fileURL
	//and track the original fileURL as our targetPath (which gets used later in _launchTarget.)
	//This way, the DOS window will show the gamebox as the represented file and our Recent Documents
	//list will likewise show the gamebox instead.
	if (packagePath)
	{
		BXPackage *package = [[BXPackage alloc] initWithPath: packagePath];
		[self setGamePackage: package];

		fileURL = [NSURL fileURLWithPath: packagePath];
		
		//If we opened a package directly, check if it has a target of its own; if so, use that as our target path.
		if ([filePath isEqualToString: packagePath])
		{
			NSString *packageTarget = [package targetPath];
			if (packageTarget) [self setTargetPath: packageTarget];
		}
		[package release];
	}

	[super setFileURL: fileURL];
}

- (BOOL) isGamePackage	{ return ([self gamePackage] != nil); }

- (NSImage *)representedIcon
{
	if ([self isGamePackage]) return [[self gamePackage] coverArt];
	else return nil;
}

- (void) setRepresentedIcon: (NSImage *)icon
{
	BXPackage *thePackage = [self gamePackage];
	if (thePackage)
	{
		[self willChangeValueForKey: @"representedIcon"];
		
		[thePackage setCoverArt: icon];
				
		//Force our file URL to appear to change, which will update icons elsewhere in the app 
		[self setFileURL: [self fileURL]];
		
		[self didChangeValueForKey: @"representedIcon"];
	}
}

- (NSArray *) executables
{
	NSWorkspace *workspace		= [NSWorkspace sharedWorkspace];
	BXPackage *thePackage		= [self gamePackage];
	
	NSString *defaultTarget		= [[thePackage targetPath] stringByStandardizingPath];
	NSArray *executablePaths	= [[thePackage executables] sortedArrayUsingSelector: @selector(pathDepthCompare:)];
	NSMutableDictionary *executables = [NSMutableDictionary dictionaryWithCapacity: [executablePaths count]];
	
	for (NSString *path in executablePaths)
	{
		path = [path stringByStandardizingPath];
		NSString *fileName	= [path lastPathComponent];
		
		//If we already have an executable with this name, skip it so we don't offer ambiguous choices
		//TODO: this filtering should be done downstream in the UI controller, it's not our call
		if (![executables objectForKey: fileName])
		{
			NSImage *icon		= [workspace iconForFile: path];
			BOOL isDefault		= [path isEqualToString: defaultTarget];
			
			NSDictionary *data	= [NSDictionary dictionaryWithObjectsAndKeys:
				path,	@"path",
				icon,	@"icon",
				[NSNumber numberWithBool: isDefault], @"isDefault",
			nil];
			
			[executables setObject: data forKey: fileName];
		}
	}
	NSArray *filteredExecutables = [executables allValues];
	
	
	NSSortDescriptor *sortDefaultFirst = [[NSSortDescriptor alloc] initWithKey: @"isDefault" ascending: NO];
	
	NSSortDescriptor *sortByFilename = [[NSSortDescriptor alloc] initWithKey: @"path.lastPathComponent"
																   ascending: YES
																	selector: @selector(caseInsensitiveCompare:)];
	
	NSArray *sortDescriptors = [NSArray arrayWithObjects:
								[sortDefaultFirst autorelease],
								[sortByFilename autorelease],
								nil];
	
	return [filteredExecutables sortedArrayUsingDescriptors: sortDescriptors];
}


- (NSArray *) documentation
{
	NSWorkspace *workspace	= [NSWorkspace sharedWorkspace];
	BXPackage *thePackage	= [self gamePackage];
	
	NSArray *docPaths = [[thePackage documentation] sortedArrayUsingSelector: @selector(pathDepthCompare:)];
	NSMutableDictionary *documentation = [NSMutableDictionary dictionaryWithCapacity: [docPaths count]];
	
	for (NSString *path in docPaths)
	{
		path = [path stringByStandardizingPath];
		NSString *fileName	= [path lastPathComponent];
		
		//If we already have a document with this name, skip it so we don't offer ambiguous choices
		//TODO: this filtering should be done downstream in the UI controller, it's not our call
		if (![documentation objectForKey: fileName])
		{
			NSImage *icon		= [workspace iconForFile: path];
			NSDictionary *data	= [NSDictionary dictionaryWithObjectsAndKeys:
				path,	@"path",
				icon,	@"icon",
			nil];
			
			[documentation setObject: data forKey: fileName];
		}
	}
	return [documentation allValues];
}

+ (NSSet *) keyPathsForValuesAffectingIsGamePackage		{ return [NSSet setWithObject: @"gamePackage"]; }
+ (NSSet *) keyPathsForValuesAffectingRepresentedIcon	{ return [NSSet setWithObject: @"gamePackage.coverArt"]; }
+ (NSSet *) keyPathsForValuesAffectingDocumentation		{ return [NSSet setWithObject: @"gamePackage.documentation"]; }
+ (NSSet *) keyPathsForValuesAffectingExecutables
{
	return [NSSet setWithObjects: @"gamePackage.executables", @"gamePackage.targetPath", nil];
}


#pragma mark -
#pragma mark Delegate methods

//If we have not already performed our own configuration, do so now
- (void) runPreflightCommands
{
	if (!hasConfigured) [self _configureEmulator];
}

//If we have not already launched our default target, do so now (and then display the program picker)
- (void) runLaunchCommands
{	
	if (!hasLaunched)
	{
		[self _launchTarget];
	}
}

- (void) frameComplete: (BXFrameBuffer *)frame
{
	[[self mainWindowController] updateWithFrame: frame];
}

- (NSSize) maxFrameSize
{
	return [[self mainWindowController] maxFrameSize];
}

- (NSSize) viewportSize
{
	return [[self mainWindowController] viewportSize];
}


#pragma mark -
#pragma mark Notifications

- (void) programWillStart: (NSNotification *)notification
{	
	//Don't set the active program if we already have one
	//This way, we keep track of when a user launches a batch file and don't immediately discard
	//it in favour of the next program the batch-file runs
	if (![self activeProgramPath])
	{
		[self setActiveProgramPath: [[notification userInfo] objectForKey: @"localPath"]];
		[mainWindowController synchronizeWindowTitleWithDocumentName];
		
		//Hide the program picker after launching the default program 
		if ([[self activeProgramPath] isEqualToString: [gamePackage targetPath]])
		{
			[[self mainWindowController] setProgramPanelShown: NO];
		}
	}
}

- (void) programDidFinish: (NSNotification *)notification
{
	//Clear the active program after every program has run during initial startup
	//This way, we don't 'hang onto' startup commands in programWillStart:
	//Once the default target has launched, we only reset the active program when
	//we return to the DOS prompt.
	if (!hasLaunched)
	{
		[self setActiveProgramPath: nil];		
	}
}

- (void) willRunStartupCommands: (NSNotification *)notification {}
- (void) didRunStartupCommands: (NSNotification *)notification {}

- (void) didReturnToShell: (NSNotification *)notification
{	
	//Clear the active program
	[self setActiveProgramPath: nil];
	[mainWindowController synchronizeWindowTitleWithDocumentName];
	
	//Show the program chooser after returning to the DOS prompt
	if ([self isGamePackage] && [[self executables] count])
	{
		BOOL panelShown = [[self mainWindowController] programPanelShown];
		
		//Show only after a delay, so that the window has time to resize after quitting the game
		if (!panelShown) [[self mainWindowController] performSelector: @selector(toggleProgramPanelShown:)
														   withObject: self
														   afterDelay: 0.5];
	}
	
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey: @"startUpInFullScreen"])
	{
		//Drop out of fullscreen mode when we return to the prompt,
		//if we automatically switched into fullscreen at startup
		[[self mainWindowController] exitFullScreen: self];
	}
}

- (void) didStartGraphicalContext: (NSNotification *)notification
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey: @"startUpInFullScreen"])
	{
		//Switch to fullscreen mode automatically after a brief delay
		//This will be cancelled if the context exits within that time - see below
		[[self mainWindowController] performSelector: @selector(toggleFullScreenWithZoom:) 
										  withObject: [NSNumber numberWithBool: YES] 
										  afterDelay: 0.5];
	}
}

- (void) didEndGraphicalContext: (NSNotification *)notification
{
	[NSObject cancelPreviousPerformRequestsWithTarget: [self mainWindowController]
											 selector: @selector(toggleFullScreenWithZoom:)
											   object: [NSNumber numberWithBool: YES]];
}

- (void) didChangeEmulationState: (NSNotification *)notification
{
	//These reside in BXEmulatorController, as should this function, but so be it
	[self willChangeValueForKey: @"sliderSpeed"];
	[self didChangeValueForKey: @"sliderSpeed"];
	
	[self willChangeValueForKey: @"frameskip"];
	[self didChangeValueForKey: @"frameskip"];
	
	[self willChangeValueForKey: @"dynamic"];
	[self didChangeValueForKey: @"dynamic"];	
}


#pragma mark -
#pragma mark Private methods


- (void) _startEmulator
{
	//The configuration files we will be using today, loaded in this order.
	NSString *preflightConf	= [[NSBundle mainBundle] pathForResource: @"Preflight" ofType: @"conf"];
	NSString *profileConf	= nil;
	NSString *packageConf	= nil;
	NSString *launchConf	= [[NSBundle mainBundle] pathForResource: @"Launch" ofType: @"conf"];
 	
	
	//Which folder to look in to detect the game we’re running.
	//This will choose any gamebox, Boxer drive folder or floppy/CD volume in the
	//file's path (setting shouldRecurse to YES) if found, falling back on the file's
	//containing folder otherwise (setting shouldRecurse to NO).
	NSString *profileDetectionPath = nil;
	BOOL shouldRecurse = NO;
	if ([self targetPath])
	{
		profileDetectionPath = [self gameDetectionPointForPath: [self targetPath] 
										shouldSearchSubfolders: &shouldRecurse];
	}
	
	//Detect any appropriate game profile for this session
	if (profileDetectionPath)
	{
		//IMPLEMENTATION NOTE: we only scan subfolders of the detection path if it's a gamebox,
		//mountable folder or CD/floppy disk, since these will have a finite and manageable file
		//heirarchy to scan.
		//Otherwise, we restrict our search to just the base folder to avoids massive blowouts
		//if the user opens something big like their home folder or startup disk, and to avoid
		//false positives when opening the DOS Games folder.
		[self setGameProfile: [BXGameProfile detectedProfileForPath: profileDetectionPath
												   searchSubfolders: shouldRecurse]];
	}
	
	
	//Get the appropriate configuration file for this game profile
	if ([self gameProfile])
	{
		NSString *configName = [[self gameProfile] confName];
		if (configName)
		{
			profileConf = [[NSBundle mainBundle] pathForResource: configName
														  ofType: @"conf"
													 inDirectory: @"Configurations"];
		}
	}
	
	//Get the gamebox's own configuration file, if it has one
	if ([self gamePackage]) packageConf = [[self gamePackage] configurationFile];
	
	
	//Load all our configuration files in order.
	[emulator applyConfigurationAtPath: preflightConf];
	if (profileConf) [emulator applyConfigurationAtPath: profileConf];
	if (packageConf) [emulator applyConfigurationAtPath: packageConf];
	[emulator applyConfigurationAtPath: launchConf];
	
	//Start up the emulator itself.
	[[self emulator] start];
	
	//Close the document once we're done.
	[self close];
}

- (void) _configureEmulator
{
	BXEmulator *theEmulator	= [self emulator];
	BXPackage *package		= [self gamePackage];
	
	if (package)
	{
		//Mount the game package as a new hard drive, at drive C
		//(This may get replaced below by a custom bundled C volume)
		BXDrive *packageDrive = [BXDrive hardDriveFromPath: [package gamePath] atLetter: @"C"];
		packageDrive = [theEmulator mountDrive: packageDrive];
		
		//Then, mount any extra volumes included in the game package
		NSMutableArray *packageVolumes = [NSMutableArray arrayWithCapacity: 10];
		[packageVolumes addObjectsFromArray: [package floppyVolumes]];
		[packageVolumes addObjectsFromArray: [package hddVolumes]];
		[packageVolumes addObjectsFromArray: [package cdVolumes]];
		
		BXDrive *bundledDrive;
		for (NSString *volumePath in packageVolumes)
		{
			bundledDrive = [BXDrive driveFromPath: volumePath atLetter: nil];
			//The bundled drive was explicitly set to drive C, override our existing C package-drive with it
			if ([[bundledDrive letter] isEqualToString: @"C"])
			{
				[[self emulator] unmountDriveAtLetter: @"C"];
				packageDrive = bundledDrive;
				//Rewrite the target to point to the new C drive, if it was pointing to the old one
				if ([[self targetPath] isEqualToString: [packageDrive path]]) [self setTargetPath: volumePath]; 
			}
			[[self emulator] mountDrive: bundledDrive];
		}
	}
	//TODO: if we're not loading a package, then C should be the DOS Games folder instead
	
	//Automount all currently mounted floppy and CD-ROM volumes
	[self mountFloppyVolumes];
	[self mountCDVolumes];
	
	//Mount our internal DOS toolkit at the appropriate drive
	NSString *toolkitDriveLetter	= [[NSUserDefaults standardUserDefaults] stringForKey: @"toolkitDriveLetter"];
	NSString *toolkitFiles			= [[NSBundle mainBundle] pathForResource: @"DOS Toolkit" ofType: nil];
	BXDrive *toolkitDrive			= [BXDrive hardDriveFromPath: toolkitFiles atLetter: toolkitDriveLetter];
	
	//Hide and lock the toolkit drive so that it will not appear in the drive manager UI
	[toolkitDrive setLocked: YES];
	[toolkitDrive setReadOnly: YES];
	[toolkitDrive setHidden: YES];
	toolkitDrive = [theEmulator mountDrive: toolkitDrive];
	
	//Point DOS to the correct paths if we've mounted the toolkit drive successfully
	//TODO: we should treat this as an error if it didn't mount!
	if (toolkitDrive)
	{
		//Todo: the DOS path should include the root folder of every drive, not just Y and Z.
		NSString *dosPath	= [NSString stringWithFormat: @"%1$@:\\;%1$@:\\UTILS;Z:\\", [toolkitDrive letter], nil];
		NSString *ultraDir	= [NSString stringWithFormat: @"%@:\\ULTRASND", [toolkitDrive letter], nil];
		
		[theEmulator setVariable: @"path"		to: dosPath		encoding: BXDirectStringEncoding];
		[theEmulator setVariable: @"ultradir"	to: ultraDir	encoding: BXDirectStringEncoding];
	}
	
	//Once all regular drives are in place, make a mount point allowing access to our target program/folder,
	//if it's not already accessible in DOS.
	if ([self targetPath])
	{
		if ([self shouldMountDriveForPath: targetPath]) [self mountDriveForPath: targetPath];
	}
	
	//Flag that we have completed our initial game configuration.
	[self willChangeValueForKey: @"isEmulating"];
	hasConfigured = YES;
	[self didChangeValueForKey: @"isEmulating"];
}

- (void) _launchTarget
{
	hasLaunched = YES;
	
	//Do any just-in-time configuration, which should override all previous startup stuff
	NSNumber *frameskip = [gameSettings objectForKey: @"frameskip"];
	
	//Set the frameskip setting if it's valid
	if (frameskip && [self validateValue: &frameskip forKey: @"frameskip" error: nil])
		[self setValue: frameskip forKey: @"frameskip"];
	
	
	//After all preflight configuration has finished, go ahead and open whatever file we're pointing at
	NSString *target = [self targetPath];
	if (target)
	{
		//If the Option key was held down, don't launch the gamebox's target;
		//Instead, just switch to its parent folder
		NSUInteger optionKeyDown = [[NSApp currentEvent] modifierFlags] & NSAlternateKeyMask;
		if (optionKeyDown != 0 && [[self class] isExecutable: target])
		{
			target = [target stringByDeletingLastPathComponent];
		}
		[self openFileAtPath: target];
	}
}

- (void) _saveConfiguration: (BXEmulatorConfiguration *)configuration toFile: (NSString *)filePath
{
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL fileExists = [manager fileExistsAtPath: filePath];
	
	//Save the configuration if any changes have been made, or if the file at that path does not exist.
	if (!fileExists || ![configuration isEmpty])
	{
		BXEmulatorConfiguration *gameboxConf = [BXEmulatorConfiguration configurationWithContentsOfFile: filePath];
		
		//If a configuration file exists at that path already, then merge
		//the changes with its existing settings.
		if (gameboxConf)
		{
			[gameboxConf addSettingsFromConfiguration: configuration];
		}
		//Otherwise, use the runtime configuration as our basis
		else gameboxConf = configuration;
		
		
		//Add comment preambles to saved configuration
		NSString *configurationHelpURL = [[NSBundle mainBundle] objectForInfoDictionaryKey: @"ConfigurationFileHelpURL"];
		if (!configurationHelpURL) configurationHelpURL = @"";
		NSString *preambleFormat = NSLocalizedStringFromTable(@"Configuration preamble", @"Configuration",
															  @"Used generated configuration files as a commented header at the top of the file. %1$@ is an absolute URL to Boxer’s configuration setting documentation.");
		[gameboxConf setPreamble: [NSString stringWithFormat: preambleFormat, configurationHelpURL, nil]];
		 
		[gameboxConf setStartupCommandsPreamble: NSLocalizedStringFromTable(@"Preamble for startup commands", @"Configuration",
																			@"Used in generated configuration files as a commented header underneath the [autoexec] section.")];
		
		
		//If we have an auto-detected game profile, check against its configuration file
		//and eliminate any duplicate configuration parameters. This way, we don't persist
		//settings we don't need to.
		NSString *profileConfName = [gameProfile confName];
		if (profileConfName)
		{
			NSString *profileConfPath = [[NSBundle mainBundle] pathForResource: profileConfName
																		ofType: @"conf"
																   inDirectory: @"Configurations"];
			
			BXEmulatorConfiguration *profileConf = [BXEmulatorConfiguration configurationWithContentsOfFile: profileConfPath];
			if (profileConf)
			{
				//First go through the settings, checking if any are the same as the profile config's.
				for (NSString *sectionName in [gameboxConf settings])
				{
					NSDictionary *section = [gameboxConf settingsForSection: sectionName];
					for (NSString *settingName in [section allKeys])
					{
						NSString *gameboxValue = [gameboxConf valueForKey: settingName inSection: sectionName];
						NSString *profileValue = [profileConf valueForKey: settingName inSection: sectionName];
						
						//If the value we'd be persisting is the same as the profile's value,
						//remove it from the persisted configuration file.
						if ([gameboxValue isEqualToString: profileValue])
							[gameboxConf removeValueForKey: settingName inSection: sectionName];
					}
				}
				
				//Now, eliminate duplicate startup commands too.
				//IMPLEMENTATION NOTE: for now we leave the startup commands alone unless the two sets
				//have exactly the same commands in the same order. There's too many risks involved 
				//for us to remove partial sets of duplicate startup commands.
				NSArray *profileCommands = [profileConf startupCommands];
				NSArray *gameboxCommands = [gameboxConf startupCommands];
				
				if ([gameboxCommands isEqualToArray: profileCommands])
					[gameboxConf removeStartupCommands];
			}
		}
		
		[gameboxConf writeToFile: filePath error: NULL];
	}
}

@end
