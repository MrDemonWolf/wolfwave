import React from 'react';
import { Series } from 'remotion';
import { loadFont as loadSpaceGrotesk } from '@remotion/google-fonts/SpaceGrotesk';
import { loadFont as loadJetBrainsMono } from '@remotion/google-fonts/JetBrainsMono';
import { IntroTitleScene } from './scenes/IntroTitleScene';
import { FeaturesShowcaseScene } from './scenes/FeaturesShowcaseScene';
import { CTAOutroScene } from './scenes/CTAOutroScene';

// Load fonts at module scope so they are registered before the first frame renders.
loadSpaceGrotesk('normal', { weights: ['700'], subsets: ['latin'] });
loadJetBrainsMono('normal', { weights: ['400'], subsets: ['latin'] });

/**
 * The full announcement: intro, feature showcase, then CTA, played back to back.
 * Scene lengths are in frames and must sum to `durationInFrames` in `Root.tsx`
 * (120 + 210 + 60 = 390).
 */
export const MainVideo: React.FC = () => (
  <Series>
    <Series.Sequence durationInFrames={120}>
      <IntroTitleScene />
    </Series.Sequence>
    <Series.Sequence durationInFrames={210}>
      <FeaturesShowcaseScene />
    </Series.Sequence>
    <Series.Sequence durationInFrames={60}>
      <CTAOutroScene />
    </Series.Sequence>
  </Series>
);
