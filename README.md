PianoTutor
=======================

An iPhone project to show how to detect frequencies of captured microphone audio. This mainly

This project uses Apple's Accelerate.framework and MoMu - A Mobile Music Toolkit from Stanford
to perform digital signal processing. I particularly tune it to detect piano playing.

To use it:

1. Launch the app
2. Play the music score notes displayed on the iPhone
3. Run the project which will detect the chords and notes, and compare what you played against
   the score and tells you how well you played.

The key element of this project is using Fast Fourier Transform to transform signals from 
time domain to frequency domain so I can detect the frequency peaks.

The challenging parts are:

1. Timing of signal capturing, processing and score displaying

2. Multiple frequencies in a piano chord

# Music-App
