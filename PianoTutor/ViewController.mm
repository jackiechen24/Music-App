#import "ViewController.h"
#import "mo_audio.h" //stuff that helps set up low-level audio
#import "FFTHelper.h"

// ## TODO
#define SAMPLE_RATE 44100  // 22050 (6s) // 44100 (3s) // 88200 (1.5s) // 176400
#define FRAMESIZE  512
#define NUMCHANNELS 2

/// Unused
//#define kOutputBus 0
//#define kInputBus 1

/// Nyquist Maximum Frequency
const Float32 NyquistMaxFreq = SAMPLE_RATE/2.0;

static float _interval = 6.0 / (SAMPLE_RATE / 22050);

// Play following notes
//
NSArray * _playbook=[NSArray arrayWithObjects:
                  @"A4",@"B4",@"C5",@"D5",@"E5",@"F5",@"G5",@"A5",
                  @"B3G3",@"B3G3F3",@"C3A3",@"C3E3G3",@"C3F3A3",
                  @"C3G3",@"E4G4",@"F3A3",@"F3G3",@"C4G4",nil];

//NSArray * _playbook=[NSArray arrayWithObjects:@"A4",@"B4",@"C5",@"D5",nil];

long _playbookSize = [_playbook count];
int _playbookIdx = 0; // Track which note is playing?

NSDictionary *_chords = @{
    @"A4": [NSArray arrayWithObjects: @440.0f,nil ],
    @"B4":[NSArray arrayWithObjects:@493.88f,nil],
    @"C5":[NSArray arrayWithObjects:@523.25f,nil],
    @"D5":[NSArray arrayWithObjects:@587.33f,nil],
    @"E5":[NSArray arrayWithObjects:@659.26f,nil],
    @"F5":[NSArray arrayWithObjects:@698.46f,nil],
    @"G5":[NSArray arrayWithObjects:@783.99f,nil],
    @"A5":[NSArray arrayWithObjects:@800.00f,nil],
    @"B3G3":[NSArray arrayWithObjects:@246.94f,@196.0f,nil],
    @"B3G3F3":[NSArray arrayWithObjects:@246.94f,@196.0f,@174.61f,nil],
    @"C3A3":[NSArray arrayWithObjects:@130.81f,@220.0f,nil],
    @"C3E3G3":[NSArray arrayWithObjects:@130.81f,@164.81f,@196.0f,nil],
    @"C3F3A3":[NSArray arrayWithObjects:@130.81f,@174.61f,@220.0f,nil],
    @"C3G3":[NSArray arrayWithObjects:@130.81f,@196.0f,nil],
    @"E4G4":[NSArray arrayWithObjects:@329.63f,@392.0f,nil],
    @"F3A3":[NSArray arrayWithObjects:@174.61f,@220.0f,nil],
    @"F3G3":[NSArray arrayWithObjects:@174.61f,@196.0f,nil],
    @"C4G4":[NSArray arrayWithObjects:@261.63f,@392.0f,nil],
};

NSDictionary *_log = [[NSMutableDictionary alloc]initWithCapacity:_playbookSize];

static long _playedRight = 0;
static long _playedWrong = 0;

/// caculates HZ value for specified index from a FFT bins vector
Float32 frequencyHerzValue(long frequencyIndex, long fftVectorSize, Float32 nyquistFrequency ) {
    return ((Float32)frequencyIndex/(Float32)fftVectorSize) * nyquistFrequency;
}

// The Main FFT Helper
FFTHelperRef *fftConverter = NULL;

// Accumulator Buffer=====================

// ## TODO
const UInt32 accumulatorDataLength = 131072;  //16384; //32768; 65536; 131072;
UInt32 accumulatorFillIndex = 0;
Float32 *dataAccumulator = nil;
static void initializeAccumulator() {
    dataAccumulator = (Float32*) malloc(sizeof(Float32)*accumulatorDataLength);
    accumulatorFillIndex = 0;
}

static void destroyAccumulator() {
    if (dataAccumulator!=NULL) {
        free(dataAccumulator);
        dataAccumulator = NULL;
    }
    accumulatorFillIndex = 0;
}

static BOOL accumulateFrames(Float32 *frames, UInt32 lenght) { //returned YES if full, NO otherwise.
    //    float zero = 0.0;
    //    vDSP_vsmul(frames, 1, &zero, frames, 1, lenght);
    
    if (accumulatorFillIndex>=accumulatorDataLength) { return YES; } else {
        memmove(dataAccumulator+accumulatorFillIndex, frames, sizeof(Float32)*lenght);
        accumulatorFillIndex = accumulatorFillIndex+lenght;
        if (accumulatorFillIndex>=accumulatorDataLength) { return YES; }
    }
    return NO;
}

static void emptyAccumulator() {
    accumulatorFillIndex = 0;
    memset(dataAccumulator, 0, sizeof(Float32)*accumulatorDataLength);
}
//=======================================

//==========================Window Buffer
const UInt32 windowLength = accumulatorDataLength;
Float32 *windowBuffer= NULL;
//=======================================
/// max value from vector with value index (using Accelerate Framework)
static Float32 vectorMaxValueACC32_index(Float32 *vector, unsigned long size, long step, unsigned long *outIndex) {
    Float32 maxVal; /* Unused */
    vDSP_maxvi(vector, step, &maxVal, outIndex, size);
    vector[ *outIndex ] = -1;
    //NSLog(@"##vmvIdx> outIndex=%lu", *outIndex);
    return maxVal;
}

///returns HZs of the strongest frequencies
/// Paul: Keep calling this func to get top 5 frequencies
static Float32* strongestFrequencies(Float32 *buffer, FFTHelperRef *fftHelper, UInt32 frameSize) {
    //the actual FFT happens here
    //****************************************************************************
    Float32 *fftData = computeFFT(fftHelper, buffer, frameSize);
    //****************************************************************************
    
    fftData[0] = 0.0;
    unsigned long length = frameSize/2.0;
    unsigned long maxIndex = 0;
    Float32 HZ;
    // ## TODO - Tune it
    int n = 10;
    static Float32 freqs[5];
    for (int i=0; i < 5; i++) {
        vectorMaxValueACC32_index(fftData, length, 1, &maxIndex);
        HZ = frequencyHerzValue(maxIndex, length, NyquistMaxFreq);
        freqs[i] = HZ;
        //NSLog(@"## %d) freq> idx=%lu hz=%0.1f", i, maxIndex, HZ);
        for (int j=0; j < n; j++) { // Zeroize nearby peaks
            fftData[maxIndex + j] = fftData[maxIndex - j] = -1;
        }
    }
    return freqs;
} // strongestFrequencies

__weak UILabel *labelInterval = nil;
__weak UILabel *labelToUpdate = nil;
__weak UILabel *labelPlay = nil;
__weak UILabel *labelChordNotes = nil;
__weak UILabel *labelDiffs = nil;
__weak UILabel *labelScore = nil;
__weak UILabel *labelPeaksTitle = nil;
__weak UILabel *labelScoreTitle = nil;

#pragma mark MAIN CALLBACK
void AudioCallback( Float32 * buffer, UInt32 frameSize, void * userData )
{
    //take only data from 1 channel
    Float32 zero = 0.0;
    vDSP_vsadd(buffer, 2, &zero, buffer, 1, frameSize*NUMCHANNELS);
    int tolerance = 10; // 7 Hz
    
    if (accumulateFrames(buffer, frameSize)==YES) { //if full
        
        //windowing the time domain data before FFT (using Blackman? Window)
        if (windowBuffer==NULL) { windowBuffer = (Float32*) malloc(sizeof(Float32)*windowLength); }
        
        vDSP_blkman_window(windowBuffer, windowLength, 0);
        vDSP_vmul(dataAccumulator, 1, windowBuffer, 1, dataAccumulator, 1, accumulatorDataLength);
        //=========================================
        
        Float32  *inPeaks = strongestFrequencies(dataAccumulator, fftConverter, accumulatorDataLength);
        NSObject *played = [_playbook objectAtIndex: _playbookIdx];
        NSArray  *playedNotes = _chords[played.description];
        NSString *playedNotesStr = @"";
        NSString *prevPeaksTitle = [NSString stringWithFormat: @"%@\nIn-Peaks", played.description];
        NSString *prevScoreTitle = [NSString stringWithFormat: @"%@\nCompare", played.description];
        NSString *compStr = @""; // Diffs by comparing played vs. chord notes
        NSString *scoreStr = @""; // Score of the played notes
        // Input notes of the played chord
        NSString *peaksStr = [NSString stringWithFormat:@"%0.1f\n%0.1f\n%0.1f\n%0.1f\n%0.1f",
                              inPeaks[0],inPeaks[1],inPeaks[2],inPeaks[3],inPeaks[4]];
        
        //NSLog(@"Played chord %@\n", played.description);
        
        // !! Compare played note freqs of the chord against top 5 input peaks
        //
        int matched = 0;

        for (NSObject *chordNote in playedNotes) {
            //NSLog(@"chordNote=%@", chordNote);
            NSNumber *num = (NSNumber*) chordNote;
            float note = [num floatValue];
            playedNotesStr = [NSString stringWithFormat: @"%@\n%0.1f", playedNotesStr, note];
            
            // Compare the chord note with the top 5 input peaks
            for (int i=0; i < 5; i++) {
                Float32 peak = inPeaks[i]; // Input freq peak
                if (peak <= 0) continue;
                //NSLog(@"%@ input peak freq=%0.1f", chord.description, p);

                float diff = abs(peak - note);
                //NSLog(@"diff=%0.1f", diff);
                if (diff < tolerance) {
                    compStr = [NSString stringWithFormat: @"%@\n%0.1f", compStr, diff];
                    inPeaks[i] = 0;
                    matched++;
                    break;
                }
            } // End each peak
        } // End each chord note
        
        scoreStr = [NSString stringWithFormat: @"%d/%lu", matched, [playedNotes count]];
        
        dispatch_async(dispatch_get_main_queue(), ^{ //update UI only on main thread
            
            _playbookIdx ++;

            // Show comparison & score //
            
            // Show chord freqs
            //
            labelChordNotes.text = playedNotesStr;
            
            // Show peaks from input
            //
            labelPeaksTitle.text = prevPeaksTitle;
            labelToUpdate.text = peaksStr;
            [_log setValue:peaksStr forKey:played.description];

            // Show comparison
            //
            labelScoreTitle.text = prevScoreTitle;
            labelDiffs.text = compStr;
            
            // Show score
            //
            if (_playbookIdx >= _playbookSize) {
                labelScore.text = scoreStr;
            }
            
            float rate = matched / [playedNotes count];
            if (rate < 0.5) {
                if (_playbookIdx >= _playbookSize) labelScore.textColor = [UIColor redColor];
                _playedWrong++;
            } else {
                if (_playbookIdx >= _playbookSize) labelScore.textColor = [UIColor greenColor];
                _playedRight++;
            }
            
            // Show prev & cur chord to play
            //
            
            if (_playbookIdx >= _playbookSize) { // Finished, show final score
                MoAudio::stop();

                NSString *logStr = @"";
                for (int i=0; i < _playbookSize; i++) {
                    NSObject* key = [_playbook objectAtIndex: i];
                    id value = _log[key.description];
                    NSLog(@"%@=\n%@\n", key, value);
                    logStr = [NSString stringWithFormat: @"%@\n%@=\n%@\n",logStr,key,value];
                }
                
                NSString *finalScoreStr = [NSString stringWithFormat: @"Done! Right:%ld Wrong:%ld\n%@", _playedRight, _playedWrong, logStr];
                labelScore.text = finalScoreStr;
                //NSLog(@"Playbook finished");
                return;
            }
            
            NSObject* nowPlay = [_playbook objectAtIndex: _playbookIdx];
               
            // Show the chord for the user to play
            //
            labelPlay.text = [NSString stringWithFormat:@"Play: %@\nPrev:%@",
                              nowPlay.description, played.description];
        });
        
        emptyAccumulator(); //empty the accumulator when finished
    }
    memset(buffer, 0, sizeof(Float32)*frameSize*NUMCHANNELS);

} // End AudioCallback

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    labelToUpdate = HZValueLabel;
    labelPlay = NoteLabel;
    labelChordNotes = ChordNotes;
    labelDiffs = CompLabel;
    labelScore = ScoreLabel; // Opaque. #lines=0: unlimited
    labelPeaksTitle = PeaksTitle;
    labelScoreTitle = ScoreTitle;
    labelInterval = IntervalLabel;

    //initialize stuff
    fftConverter = FFTHelperCreate(accumulatorDataLength);
    initializeAccumulator();
    [self initMomuAudio];
}

-(void) initMomuAudio {
    bool result = false;
    result = MoAudio::init( SAMPLE_RATE, FRAMESIZE, NUMCHANNELS, false);
    if (!result) { NSLog(@" MoAudio init ERROR"); }

    NSObject* play = [_playbook objectAtIndex: 0];
    
    // Show the chord for the user to play
    //
    labelPlay.text = [NSString stringWithFormat:@"Play:%@\nPrev:\n", play.description];
    
    labelInterval.text = [NSString stringWithFormat:@"Interval=%0.1f secs", _interval];
    
    // Show chord notes
    //
    
    // Combine chord notes into a string first
    NSArray  *chordNotes = _chords[play.description];
    NSString *chordNotesStr = @"";
    
    for (NSObject *chordNote in chordNotes) {
        NSNumber *num = (NSNumber*) chordNote;
        float note = [num floatValue];
        chordNotesStr = [NSString stringWithFormat: @"%@\n%0.1f", chordNotesStr, note];
    }
    
    // Show the string of chord notes
    labelChordNotes.text = chordNotesStr;
        
    result = MoAudio::start( AudioCallback, NULL );
    if (!result) { NSLog(@" MoAudio start ERROR"); }
        
} // End initMomuAudio

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

-(void) dealloc {
    destroyAccumulator();
    FFTHelperRelease(fftConverter);
}

@end
