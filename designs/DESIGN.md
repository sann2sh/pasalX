---
name: Nordic Botanical & Slate
colors:
  surface: '#f4fbf6'
  surface-dim: '#d4dcd7'
  surface-bright: '#f4fbf6'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#eef5f0'
  surface-container: '#e8f0ea'
  surface-container-high: '#e3eae5'
  surface-container-highest: '#dde4df'
  on-surface: '#161d1a'
  on-surface-variant: '#404944'
  inverse-surface: '#2b322f'
  inverse-on-surface: '#ebf2ed'
  outline: '#707974'
  outline-variant: '#c0c9c2'
  surface-tint: '#356853'
  primary: '#215542'
  on-primary: '#ffffff'
  primary-container: '#3b6e59'
  on-primary-container: '#b7eed4'
  inverse-primary: '#9cd2b9'
  secondary: '#416657'
  on-secondary: '#ffffff'
  secondary-container: '#c0e9d6'
  on-secondary-container: '#456a5b'
  tertiary: '#454f4b'
  on-tertiary: '#ffffff'
  tertiary-container: '#5d6762'
  on-tertiary-container: '#dbe5df'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#b8eed4'
  primary-fixed-dim: '#9cd2b9'
  on-primary-fixed: '#002115'
  on-primary-fixed-variant: '#1b503c'
  secondary-fixed: '#c3ecd9'
  secondary-fixed-dim: '#a7cfbd'
  on-secondary-fixed: '#002116'
  on-secondary-fixed-variant: '#294e40'
  tertiary-fixed: '#dbe5df'
  tertiary-fixed-dim: '#bfc9c3'
  on-tertiary-fixed: '#151d1a'
  on-tertiary-fixed-variant: '#3f4945'
  background: '#f4fbf6'
  on-background: '#161d1a'
  surface-variant: '#dde4df'
typography:
  display-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 3.5rem
    fontWeight: '400'
    lineHeight: 4rem
    letterSpacing: -0.03em
  display-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 2.25rem
    fontWeight: '400'
    lineHeight: 2.75rem
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 2rem
    fontWeight: '500'
    lineHeight: 2.5rem
    letterSpacing: -0.02em
  headline-lg-mobile:
    fontFamily: Plus Jakarta Sans
    fontSize: 1.5rem
    fontWeight: '500'
    lineHeight: 2rem
    letterSpacing: -0.015em
  headline-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 1.25rem
    fontWeight: '600'
    lineHeight: 1.75rem
    letterSpacing: -0.01em
  body-lg:
    fontFamily: Plus Jakarta Sans
    fontSize: 1.125rem
    fontWeight: '400'
    lineHeight: 1.75rem
    letterSpacing: -0.005em
  body-md:
    fontFamily: Plus Jakarta Sans
    fontSize: 0.9375rem
    fontWeight: '400'
    lineHeight: 1.5rem
    letterSpacing: 0em
  body-sm:
    fontFamily: Plus Jakarta Sans
    fontSize: 0.8125rem
    fontWeight: '400'
    lineHeight: 1.25rem
    letterSpacing: 0.01em
  label-md:
    fontFamily: Inter
    fontSize: 0.75rem
    fontWeight: '600'
    lineHeight: 1rem
    letterSpacing: 0.08em
  label-sm:
    fontFamily: Inter
    fontSize: 0.6875rem
    fontWeight: '500'
    lineHeight: 0.875rem
    letterSpacing: 0.1em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 1.5rem
  gutter-mobile: 1rem
  margin: 3rem
  margin-mobile: 1.25rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2.5rem
---

## Brand & Style

This design system embodies the disciplined serenity of Scandinavian minimalism merged with Japanese editorial cosmetics. It evokes clinical clarity, organic stillness, and sensory restraint. The visual atmosphere is that of a quiet apothecary showroom: light-filled, deliberate, tactile, and stripped of ornamentation.

The visual signature is driven by high negative space, razor-sharp architectural contours, meticulously tuned typography, and a deliberate absence of heavy drop shadows or synthetic gloss. Every element must appear calibrated and intentional, instilling quiet authority and unhurried purity.

## Colors

The palette is rooted in botanical extraction and mineral neutrality:

- **Canvas & Base:** `#F7F9F8` (Chalk White) acts as the uncompromised substrate for all views.
- **Card & Surface Tiers:** `#EEF3F0` (Tincture Mint/Sage) provides subtle textural separation from the canvas without introducing heavy tonal contrast. Secondary nested panels utilize `#E4ECE7`.
- **Text & Foreground:** `#1E2522` (Slate Zinc Charcoal) delivers clinical legibility with softer optic density than pure carbon black. Secondary muted text uses `#525F59`.
- **Primary Accent:** `#3B6E59` (Botanical Sage/Eucalyptus) drives focused action points, active indicators, and brand focal anchors.
- **Subtle Structural Delimiters:** `#D8E2DC` (Pressed Clay) defines precise 1px hairline boundaries and container rules.

Avoid gradients, saturated neon tones, or warm golden accents. Keep contrast ratios strictly compliant while maintaining an airy, organic impression.

## Typography

Typography combines the human geometric balance of **Plus Jakarta Sans** with the structural discipline of **Inter** for micro-data, catalog codes, and apothecary formulations.

- **Editorial Serenity:** Headlines favor lighter weights (`400`–`500`) with tight tracking to simulate high-end packaging.
- **Data & Micro-Labels:** `label-md` and `label-sm` should be rendered in uppercase with deliberate tracking (`0.08em` to `0.1em`) to mimic stamped batch codes and botanical classifications.
- **Reading Rhythm:** Body copy maintains a generous 1.5 to 1.6 line-height ratio, ensuring long-form botanical formulas or ritual descriptions remain effortless to read.

## Layout & Spacing

The layout is built on a 12-column fluid grid on desktop (`> 1024px`), an 8-column layout on tablet (`768px - 1023px`), and a 4-column layout on mobile (`< 768px`).

- **Negative Space Allocation:** White space is treated as an active graphic component. Sections require generous vertical separation (`space-xl` scaled to 4rem+ between blocks).
- **Alignment:** Content aligns flush to strict hairline vertical axes. Asymmetry is permitted only for hero imagery and editorial showcases where text stacks directly adjacent to product portraiture.
- **Reflow:** On mobile, margins reduce from `3rem` to `1.25rem`, while nested card padding preserves breathable internal air using `space-md` (`1rem`).

## Elevation & Depth

This system avoids synthetic drop shadows, skeuomorphic bevels, and heavy layered elevations. Visual depth is established through:

- **Low-Contrast Outlines:** Hairline 1px borders using `#D8E2DC` provide boundary definition for floating cards and structural dividers.
- **Tonal Stepping:** Surfaces stack cleanly via color shift: `#F7F9F8` (Canvas) &rarr; `#EEF3F0` (Card Layer) &rarr; `#FFFFFF` (Floating Action Popovers or Dialogs).
- **Subtle Surface Tinting:** Hover states and pressed surfaces shift down to `#E4ECE7` without changing geometry or introducing elevated blur.
- **Ephemeral Overlays:** Modals use an unblurred 20% opacity wash of `#1E2522`, anchoring the focus without theatrical distortion.

## Shapes

The shape system adopts a minimal corner radius (`roundedness: 1`), keeping silhouettes crisp, architectural, and grounded.

- **Base Radii:** 0.25rem (`4px`) on input fields, buttons, and utility tags.
- **Cards & Modals:** Large cards and floating modules use `rounded-lg` (`0.5rem` / `8px`), maintaining an exacting, tailored posture rather than an informal, bubbly one.
- **Pill Exceptions:** Interactive status indicators and ingredient filter chips may strictly employ fully circular pills only when differentiating metadata tags from actionable containers.

## Components

### Buttons
- **Primary:** Solid `#3B6E59` background with `#F7F9F8` text. 0.25rem radius. Zero drop shadow. Hover shifts to `#325C4B`.
- **Secondary / Outline:** 1px hairline border in `#1E2522` over transparent canvas, with `#1E2522` text. Hover shifts background to `#EEF3F0`.
- **Ghost:** Transparent background with `#3B6E59` text and subtle underline on hover.
- **Padding:** 0.75rem vertical by 1.5rem horizontal for standard interactive CTAs.

### Input Fields
- **Container:** Background `#EEF3F0`, 1px border `#D8E2DC`.
- **States:** Focus replaces border with `#3B6E59` (no thick glow; clean 1px transition). Placeholder text rendered in `#525F59` at `body-sm`.
- **Labels:** Positioned strictly above fields in `label-md`, tracked uppercase `#1E2522`.

### Cards & Apothecary Tiles
- **Surface:** `#EEF3F0` background framed by a razor `#D8E2DC` 1px border.
- **Padding:** Generous internal padding using `space-lg` (`1.5rem`).
- **Structure:** Content layout stacks vertically: batch/category label (`label-sm`), item headline (`headline-sm`), formulation details (`body-sm`), followed by a flush-bottom metadata grid.

### Chips & Filters
- **Dormant:** Outline only (`1px solid #D8E2DC`), transparent fill, `#1E2522` text.
- **Selected:** Solid `#3B6E59` fill with `#F7F9F8` text.
- **Typography:** `label-md` tracking.

### Checkboxes & Radio Controls
- **Geometry:** Checkboxes use 2px rounded corners; radio controls are circular.
- **Palette:** Inactive state features a 1px `#D8E2DC` border on `#FFFFFF`. Active state fills with `#3B6E59` featuring a crisp chalk checkmark or dot.

### Lists & Spec Grids
- **Apothecary Data Tables:** Minimalist rows separated by 1px `#D8E2DC` horizontal hairlines. No vertical dividers. Left column holds botanical classification in `label-md`; right column displays composition percentages or measurements in `body-sm`.