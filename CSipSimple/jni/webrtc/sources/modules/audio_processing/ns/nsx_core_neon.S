@
@ Copyright (c) 2012 The WebRTC project authors. All Rights Reserved.
@
@ Use of this source code is governed by a BSD-style license
@ that can be found in the LICENSE file in the root of the source
@ tree. An additional intellectual property rights grant can be found
@ in the file PATENTS.  All contributing project authors may
@ be found in the AUTHORS file in the root of the source tree.
@

@ nsx_core_neon.s
@ This file contains some functions in NS, optimized for ARM Neon
@ platforms. Reference C code is in file nsx_core.c. Bit-exact.

.arch armv7-a
.fpu neon

#include "nsx_defines.h"
#include "nsx_core_neon_offsets.h"

.global WebRtcNsx_NoiseEstimationNeon
.global WebRtcNsx_PrepareSpectrumNeon
.global WebRtcNsx_SynthesisUpdateNeon
.global WebRtcNsx_AnalysisUpdateNeon
.global WebRtcNsx_DenormalizeNeon
.global WebRtcNsx_CreateComplexBufferNeon

@ void NoiseEstimationNeon(NsxInst_t* inst,
@                          uint16_t* magn,
@                          uint32_t* noise,
@                          int16_t* q_noise);

@ Register usage (across major loops of NoiseEstimationNeon()):
@ r0-r3: function arguments, and scratch registers.
@ r4: &inst
@ r5: &noiseEstLogQuantile[]
@ r6: inst->magnLen
@ r7: offset
@ r8: s, the loop counter for the LOOP_SIMULT
@ r9: &inst->noiseEstDensity[]
@ r10: &inst->noiseEstCounter[]
@ r11: countDiv
@ r12: i, the loop counter for LOOP_NOISEESTIMATION_MAGNLEN_INNER

WebRtcNsx_NoiseEstimationNeon:
.fnstart
.save {r4-r11, r14}
.vsave {d8-d15}
.pad #(16 + (HALF_ANAL_BLOCKL + 3) / 4 * 8)

  push {r4-r11, r14}
  vpush {d8-d15}
  sub sp, #(16 + (HALF_ANAL_BLOCKL + 3) / 4 * 8)

@ [sp, #0]: logval
@ [sp, #4]: noise
@ [sp, #8]: q_noise
@ [sp, #12]: factor
@ [sp, #16 ~ #(16 + (HALF_ANAL_BLOCKL + 3) / 4 * 8)]: lmagn[HALF_ANAL_BLOCKL]

  str r2, [sp, #4]            @ noise
  str r3, [sp, #8]            @ q_noise
  movw r4, #offset_nsx_normData
  ldr r2, [r0, #offset_nsx_stages]            @ inst->stages
  ldr r4, [r0, r4]            @ inst->normData
  ldr r12, =WebRtcNsx_kLogTable
  subs r3, r2, r4             @ tabind = inst->stages - inst->normData;
  ldr r5, [r0, #offset_nsx_magnLen]            @ magnLen
  rsblt r3, #0
  lsl r3, #1
  ldrh r3, [r12, r3]          @ logval = WebRtcNsx_kLogTable[tabind];
  add r12, sp, #16            @ lmagn[]
  rsblt r3, #0                @ logval = -WebRtcNsx_kLogTable[-tabind];
  str r3, [sp]
  vdup.16 q15, r3

  ldr r9, =WebRtcNsx_kLogTableFrac

LOOP_SET_LMAGN:
  ldrh r2, [r1], #2           @ magn[i]
  cmp r2, #0
  streqh r3, [r12], #2        @ lmagn[i] = logval;
  beq CHECK_LMAGN_COUNTER

  clz r6, r2
  mov r4, r6                  @ zeros
  rsb r6, #31
  lsl r2, r4
  ubfx r4, r2, #23, #8
  mov r2, r4, lsl #1
  ldrh r4, [r9, r2]           @ WebRtcNsx_kLogTableFrac[frac]
  add r7, r4, r6, lsl #8      @ log2
  movw r2, #22713             @ log2_const
  smulbb r2, r7, r2
  add r2, r3, r2, lsr #15
  strh r2, [r12], #2          @ lmagn[i]

CHECK_LMAGN_COUNTER:
  subs r5, #1
  bgt LOOP_SET_LMAGN

  movw r3, #21845             @ width_factor
  vdup.16 q5, r3
  vmov.s16 q14, #WIDTH_Q8

  movw r5, #offset_nsx_noiseEstLogQuantile
  movw r7, #offset_nsx_blockIndex
  movw r9, #offset_nsx_noiseEstDensity
  add r5, r0
  ldr r6, [r0, #offset_nsx_magnLen]
  ldr r7, [r0, r7]
  add r9, r0
  cmp r7, #END_STARTUP_LONG
  add r10, r0, #offset_nsx_noiseEstCounter
  movge r7, #FACTOR_Q7
  movlt r7, #FACTOR_Q7_STARTUP
  mov r4, r0
  str r7, [sp, #12]           @ factor
  mov r8, #SIMULT
  mov r7, #0

LOOP_SIMULT:
  ldrsh r1, [r10]             @ inst->noiseEstCounter[s]
  ldr r3, =WebRtcNsx_kCounterDiv
  mov r11, r1, lsl #1         @ counter
  ldrh r11, [r3, r11]         @ countDiv = WebRtcNsx_kCounterDiv[counter];
  sub r12, r6, #1             @ Loop counter.
  smulbb r3, r1, r11          @ countProd
  vdup.16 q11, r11

  vqrdmulh.s16 q11, q5, q11   @ WEBRTC_SPL_MUL_16_16_RSFT_WITH_ROUND(
                              @   width_factor, countDiv, 15);
  vdup.16 d24, r11
  vdup.16 d25, r3

  ldr r3, [sp, #12]           @ factor
  add r1, sp, #16             @ &lmagn[0]
  vdup.16 q9, r3
  vmov.i16 q13, #512
  vmov.i16 q7, #15
  vmov.i32 q6, #FACTOR_Q16

LOOP_NOISEESTIMATION_MAGNLEN_INNER:
  vld1.16 {q0}, [r9]          @ noiseEstDensity[offset + i]

  @ Compute delta in the next two blocks.
  vclz.i16 q4, q0
  vsub.i16 q4, q4, q7         @ Value of the shift factors; likely negative.
  vmovl.s16 q3, d8
  vmovl.s16 q2, d9

  vshl.s32 q1, q6, q3
  vmovn.i32 d8, q1            @ d8 holds shifted FACTOR_Q16.
  vshl.s32 q1, q6, q2
  vcgt.s16 q3, q0, q13        @ Compare noiseEstDensity to 512.
  vmovn.i32 d9, q1            @ d9 holds shifted FACTOR_Q16.
  vmov.i16 q1, q9
  vbit.s16 q1, q4, q3         @ If bigger than 512, delta = shifted FACTOR_Q16.

  vmull.s16 q8, d3, d24
  vmull.s16 q4, d2, d24
  vshrn.i32 d2, q4, #14
  vshrn.i32 d3, q8, #14

  vrshr.s16 q3, q1, #1
  vrshr.s16 q8, q1, #2
  vmull.s16 q4, d7, d28
  vmull.s16 q3, d6, d28
  vld1.16 {q10}, [r5]         @ inst->noiseEstLogQuantile[offset + i]
  vshrn.i32 d4, q3, #1
  vshrn.i32 d5, q4, #1

  vld1.16 {q3}, [r1]!         @ lmagn[i]
  vsub.i16 q4, q10, q2
  vadd.i16 q8, q10, q8
  vsub.i16 q2, q3, q10
  vmax.s16 q4, q4, q15
  vcgt.s16 q1, q2, #0
  vbit q10, q8, q1
  vbif q10, q4, q1

  vsub.i16 q1, q3, q10
  vst1.16 {q10}, [r5]!        @ inst->noiseEstLogQuantile[offset + i]
  vabs.s16 q4, q1
  vqrdmulh.s16 d2, d0, d25
  vqrdmulh.s16 d3, d1, d25
  vcgt.s16 q4, q14, q4
  vadd.i16 q1, q1, q11
  vbit q0, q1, q4
  subs r12, #8
  vst1.16 {q0}, [r9]!         @ noiseEstDensity[offset + i]
  bgt LOOP_NOISEESTIMATION_MAGNLEN_INNER

@
@ Last iteration over magnitude spectrum.
@

COMPUTE_DELTA:
  ldrsh r2, [r9]              @ inst->noiseEstDensity[offset + i]
  cmp r2, #512
  bgt COMPUTE_DELTA_BIGGER_DENSITY

  movw r2, #offset_nsx_blockIndex
  ldr r0, [r4, r2]
  cmp r0, #END_STARTUP_LONG
  movge r0, #FACTOR_Q7          @ delta
  movlt r0, #FACTOR_Q7_STARTUP  @ delta
  b UPDATE_LOG_QUANTILE_ESTIMATE

COMPUTE_DELTA_BIGGER_DENSITY:
  clz r2, r2
  rsb r0, r2, #31             @ 14 - factor
  mov r2, #FACTOR_Q16
  mov r0, r2, lsr r0          @ FACTOR_Q16 >> (14 - factor)

UPDATE_LOG_QUANTILE_ESTIMATE:
  smulbb r12, r0, r11
  ldrsh r1, [r1]              @ lmagn[i]
  ubfx r12, r12, #14, #16     @ tmp16
  ldrsh r2, [r5]              @ inst->noiseEstLogQuantile[offset + i]
  cmp r1, r2
  bgt UPDATE_LOG_QUANTILE_ESTIMATE_BIGGER_LMAGN

  add r12, #1
  ldr r3, [sp]                @ logval
  mov r0, r12, lsr #1         @ tmp16no1
  mov r12, #3
  smulbb r12, r0, r12         @ tmp16no2
  sub r2, r12, lsr #1
  cmp r3, r2
  ldrgt r2, [sp]
  ldrgt r3, [sp]
  b UPDATE_LOG_QUANTILE_ESTIMATE_STORE

UPDATE_LOG_QUANTILE_ESTIMATE_BIGGER_LMAGN:
  add r3, r12, #2
  add r2, r3, lsr #2

UPDATE_LOG_QUANTILE_ESTIMATE_STORE:
  vmov.s16 r0, d25[0]         @ countProd
  strh r2, [r5]
  add r5, #2                  @ increment &noiseEstLogQuantile[offset + i]

UPDATE_DENSITY_ESTIMATE:
  subs r12, r1, r2
  rsblt r12, #0
  cmp r12, #WIDTH_Q8
  bge UPDATE_DENSITY_ESTIMATE_CHECK_COUNTER

  movw r3, #21845             @ width_factor
  ldrh r12, [r9]              @ inst->noiseEstDensity[offset + i]
  smulbb r2, r3, r11
  smulbb r1, r12, r0
  add r0, r2, #1 << 14        @ Rounding
  add r12, r1, #1 << 14
  mov r1, r12, lsr #15
  add r3, r1, r0, lsr #15
  strh r3, [r9]               @ inst->noiseEstDensity[offset + i]

UPDATE_DENSITY_ESTIMATE_CHECK_COUNTER:
  add r9, #2                  @ updata &noiseEstDensity[offset + i]
  ldrsh r3, [r10]             @ inst->noiseEstCounter[s]
  cmp r3, #END_STARTUP_LONG
  blt POST_UPDATE_DENSITY_ESTIMATE

  movw r2, #offset_nsx_blockIndex
  mov r12, #0
  ldr r2, [r4, r2]
  strh r12, [r10]
  cmp r2, #END_STARTUP_LONG
  blt POST_UPDATE_DENSITY_ESTIMATE

  mov r0, r4
  mov r1, r7
  bl UpdateNoiseEstimateNeon

POST_UPDATE_DENSITY_ESTIMATE:
  ldrh r3, [r10]
  add r3, #1
  strh r3, [r10], #2
  subs r8, #1
  add r7, r6                  @ offset += inst->magnLen;
  bgt LOOP_SIMULT

  movw r2, #offset_nsx_blockIndex
  ldr r2, [r4, r2]
  cmp r2, #END_STARTUP_LONG
  bge UPDATE_NOISE

  sub r1, r7, r6
  mov r0, r4
  bl UpdateNoiseEstimateNeon

UPDATE_NOISE:
  movw r1, #offset_nsx_noiseEstQuantile
  add r1, r4
  ldr r2, [sp, #4]

@ Initial value of loop counter r6 = inst->magnLen.
LOOP_UPDATE_NOISE:
  ldrsh r0, [r1], #2
  subs r6, #1
  str r0, [r2], #4
  bgt LOOP_UPDATE_NOISE

UPDATE_Q_NOISE:
  movw r2, #offset_nsx_qNoise
  ldr r1, [sp, #8]
  ldrh r2, [r4, r2]
  strh r2, [r1]

  add sp, #(16 + (HALF_ANAL_BLOCKL + 3) / 4 * 8)
  vpop {d8-d15}
  pop {r4-r11, pc}
.fnend

@ static void UpdateNoiseEstimateNeon(NsxInst_t* inst, int offset);
@ Neon registers touched: q0-q3, q8-q13.
UpdateNoiseEstimateNeon:
.fnstart
.save {r4, r5, r6, r14}

  push {r4, r5, r6, r14}
  mov r5, r0

  vmov.i32 q10, #21
  vmov.i32 q11, #0x1FFFFF
  vmov.i32 q9, #0x200000

  movw r0, #offset_nsx_noiseEstLogQuantile
  movw r6, #offset_nsx_magnLen
  add r0, r5                  @ &inst->noiseEstLogQuantile
  add r4, r0, r1, lsl #1      @ &inst->noiseEstLogQuantile[offset]
  ldrsh r6, [r5, r6]          @ &inst->magnLen

  mov r0, r4
  mov r1, r6
  bl WebRtcSpl_MaxValueW16Neon

  sub r12, r6, #1             @ Loop counter: inst->magnLen - 1.

  movw r6, #11819             @ kExp2Const in Q13
  movw r2, #offset_nsx_noiseEstQuantile
  vdup.16 d16, r6
  smulbb r3, r6, r0
  add r0, r3, #1 << 20        @ Round
  movw r1, #offset_nsx_qNoise
  mov r0, r0, lsr #21
  rsb r0, r0, #14             @ 14 - (round(kExp2Const * tmp16) >> 21)
  add r2, r5                  @ &inst->noiseEstQuantile
  vdup.32 q13, r0
  str r0, [r5, r1]

LOOP_UPDATE:
  vld1.16 {d0, d1}, [r4]!     @ &inst->noiseEstLogQuantile[offset + i]
  vmull.s16 q1, d0, d16
  vmull.s16 q0, d1, d16
  vshr.s32 q3, q1, #21
  vshr.s32 q2, q0, #21
  vand q1, q1, q11
  vand q0, q0, q11
  vsub.i32 q3, q3, q10
  vsub.i32 q2, q2, q10
  vorr q1, q1, q9
  vorr q0, q0, q9
  vadd.i32 q3, q3, q13
  vadd.i32 q2, q2, q13
  vshl.s32 q1, q1, q3
  vshl.s32 q0, q0, q2
  vqmovn.s32 d1, q0
  vqmovn.s32 d0, q1
  subs r12, #8
  vst1.16 {d0, d1}, [r2]!
  bgt LOOP_UPDATE

POST_LOOP_MAGNLEN:
  ldrh r1, [r4]
  smulbb r3, r6, r1           @ kExp2Const * ptr_noiseEstLogQuantile[offset + i]
  mov r12, #0x00200000
  bfi r12, r3, #0, #21        @ tmp32no1 = 0x00200000 | (tmp32no2 & 0x001FFFFF);
  rsb r0, #21                 @ 21 - &inst->qNoise
  sub r14, r0, r3, lsr #21    @ -tmp16
  mov r0, r12, lsr r14
  ssat r3, #16, r0
  strh r3, [r2]

  pop {r4, r5, r6, pc}
.fnend

@ void PrepareSpectrumNeon(NsxInst_t* inst, int16_t* freq_buf);
WebRtcNsx_PrepareSpectrumNeon:
.fnstart
.save {r4-r8}

  push {r4-r8}

  movw r2, #offset_nsx_real
  movw r12, #offset_nsx_noiseSupFilter
  movw r4, #offset_nsx_imag
  movw r5, #offset_nsx_magnLen

  add r2, r0                  @ &inst->real[0]
  add r4, r0                  @ &inst->image[0]
  mov r9, r4                  @ &inst->image[0]
  mov r3, r2                  @ &inst->real[0]
  ldr r5, [r0, r5]            @ inst->magnLen
  add r6, r4, #2              @ &inst->image[1]
  sub r5, #1
  add r12, r0                 @ &inst->noiseSupFilter[0]
  add r5, r2, r5, lsl #1      @ &inst->real[inst->magnLen - 1]

LOOP_MAGNLEN:
  @ Filter the elements.
  vld1.16 {d20, d21}, [r2]    @ inst->real[]
  vld1.16 {d24, d25}, [r12]!  @ inst->noiseSupFilter[]
  vld1.16 {d22, d23}, [r4]    @ inst->imag[]
  vmull.s16 q0, d20, d24
  vmull.s16 q1, d21, d25
  vmull.s16 q2, d22, d24
  vmull.s16 q3, d23, d25
  vshrn.s32 d0, q0, #14
  vshrn.s32 d1, q1, #14
  vshrn.s32 d2, q2, #14
  vshrn.s32 d3, q3, #14
  vst1.16 {d0, d1}, [r2]!
  vst1.16 {d2, d3}, [r4]!
  cmp r2, r5
  bcc LOOP_MAGNLEN

  @ Last two elements to filter:
  ldrh r7, [r2]
  ldrh r8, [r12]
  ldrh r5, [r4]
  smulbb r7, r7, r8
  smulbb r5, r5, r8
  mov r7, r7, lsr #14
  mov r8, r5, lsr #14
  strh r7, [r2]
  strh r8, [r4]

  ldr r5, [r0, #offset_nsx_anaLen2]            @ inst->anaLen2
  ldr r7, [r0, #offset_nsx_anaLen]            @ inst->anaLen
  add r5, r3, r5, lsl #1      @ &inst->real[inst->anaLen2]

  ldrh r2, [r3], #2           @ inst->real[0]
  ldrh r0, [r9]               @ inst->imag[0]
  strh r2, [r1], #2           @ Store to freq_buf[0]
  rsb r0, r0, #0
  strh r0, [r1], #2           @ Store to freq_buf[1]. Now r1 -> &freq_buf[2]

  add r2, r1, r7, lsl #2
  sub r2, #36                 @ &freq_buf[-16]

  mvn r12, #0x1F              @ -32

@ At the last iteration, &freq_buf[inst->anaLen + 1] will be written to by both
@ the vst1 instructions. Only the 2nd vst1 instruction has the correct value
@ (-inst->imag[inst->anaLen2]), so the order of the two vst1's is important.
LOOP_ANALEN2:
  vld1.16 {d0, d1}, [r3]!     @ inst->real[], starting from inst->real[1]
  vld1.16 {d2, d3}, [r6]!     @ inst->imag[], starting from inst->imag[1]
  vmov.s16 d4, d0
  vmov.s16 d6, d1
  vneg.s16 d5, d2
  vneg.s16 d7, d3
  vzip.16 d0, d2
  vzip.16 d1, d3
  vzip.16 d4, d5
  vzip.16 d6, d7
  vrev64.32 d16, d3
  vrev64.32 d17, d1
  vrev64.32 d18, d2
  vrev64.32 d19, d0
  cmp r3, r5
  vst1.16 {d16, d17, d18, d19}, [r2], r12
  vst1.16 {d4, d5, d6, d7}, [r1]!
  bls LOOP_ANALEN2

  pop {r4-r8}
  bx r14
.fnend

@ void WebRtcNsx_DenormalizeNeon(NsxInst_t* inst, int16_t* in, int factor);
WebRtcNsx_DenormalizeNeon:
.fnstart
  movw r12, #offset_nsx_normData
  movw r3, #offset_nsx_real
  ldr r12, [r0, r12]          @ inst->normData
  add r3, r0                  @ &inst->real[0]
  sub r2, r12
  vdup.32 q10, r2

  movw r2, #offset_nsx_anaLen
  ldrsh r2, [r0, r2]          @ inst->anaLen
  add r0, r3, r2, lsl #1      @ &inst->real[inst->anaLen]

LOOP_ANALEN:
  vld2.16 {d0, d1}, [r1]!     @ &in[]
  vld2.16 {d2, d3}, [r1]!     @ &in[]
  vmovl.s16 q2, d0
  vmovl.s16 q3, d2
  vshl.s32 q2, q10
  vshl.s32 q3, q10
  vqmovn.s32 d0, q2
  vqmovn.s32 d1, q3
  vst1.16 {d0, d1}, [r3]!     @ inst->real[]
  cmp r3, r0
  blt LOOP_ANALEN

  bx r14
.fnend

@ void SynthesisUpdateNeon(NsxInst_t* inst,
@                          int16_t* out_frame,
@                          int16_t gain_factor);
WebRtcNsx_SynthesisUpdateNeon:
.fnstart
.save {r4, r5}
  push {r4, r5}

  vdup.16 d31, r2

  movw r2, #offset_nsx_anaLen
  movw r4, #offset_nsx_real
  movw r12, #offset_nsx_synthesisBuffer

  ldrsh r5, [r0, r2]          @ inst->anaLen
  add r12, r0                 @ &inst->synthesisBuffer[0];
  ldr r3, [r0, #offset_nsx_window]            @ &inst->window[0]
  add r4, r0                  @ &inst->real[0]
  add r5, r12, r5, lsl #1     @ &inst->synthesisBuffer[inst->anaLen]

  mov r2, r12                 @ &inst->synthesisBuffer[0];

LOOP_SYNTHESIS:
  vld1.16 {d0, d1}, [r4]!     @ inst->real[]
  vld1.16 {d2, d3}, [r3]!     @ inst->window[]
  vld1.16 {d4, d5}, [r2]      @ inst->synthesisBuffer[];
  vmull.s16 q3, d0, d2
  vmull.s16 q8, d1, d3
  vrshrn.i32 d0, q3, #14
  vrshrn.i32 d1, q8, #14
  vmull.s16 q3, d31, d0
  vmull.s16 q8, d31, d1
  vqrshrn.s32 d0, q3, #13
  vqrshrn.s32 d1, q8, #13
  vqadd.s16 d4, d0
  vqadd.s16 d5, d1
  vst1.16 {d4, d5}, [r2]!
  cmp r2, r5
  blt LOOP_SYNTHESIS

POST_LOOP_SYNTHESIS:
  movw r3, #offset_nsx_blockLen10ms
  ldr r2, [r0, r3]
  mov r3, r12                 @ &inst->synthesisBuffer[0];
  add r0, r12, r2, lsl #1     @ &inst->synthesisBuffer[inst->blockLen10ms]

LOOP_BLOCKLEN10MS:
  vld1.16 {q0, q1}, [r3]!     @ inst->synthesisBuffer[];
  cmp r3, r0
  vst1.16 {q0, q1}, [r1]!     @ out_frame[]
  blt LOOP_BLOCKLEN10MS

  cmp r0, r5
  bge POST_LOOP_MEMCPY

LOOP_MEMCPY:
  vld1.16 {q0, q1}, [r0]!     @ inst->synthesisBuffer[i + inst->blockLen10ms]
  cmp r0, r5
  vst1.16 {q0, q1}, [r12]!    @ inst->synthesisBuffer[i]
  blt LOOP_MEMCPY

POST_LOOP_MEMCPY:
  cmp r12, r5
  vmov.i16 q10, #0
  vmov.i16 q11, #0
  bge EXIT_SYNTHESISUPDATE

LOOP_ZEROSARRAY:
  vst1.16 {q10, q11}, [r12]!  @ inst->synthesisBuffer[i + inst->anaLen]
  cmp r12, r5
  blt LOOP_ZEROSARRAY

EXIT_SYNTHESISUPDATE:
  pop {r4, r5}
  bx r14

.fnend

@ void AnalysisUpdateNeon(NsxInst_t* inst, int16_t* out, int16_t* new_speech);
WebRtcNsx_AnalysisUpdateNeon:
.fnstart
.save {r4-r6}
  push {r4-r6}

  movw r3, #offset_nsx_analysisBuffer
  movw r4, #offset_nsx_anaLen
  movw r12, #offset_nsx_blockLen10ms
  add r3, r0                  @ &inst->analysisBuffer[0]
  ldrsh r4, [r0, r4]          @ inst->anaLen
  ldr r12, [r0, r12]          @ inst->blockLen10ms
  sub r6, r4, r12
  add r6, r3, r6, lsl #1      @ &inst->analysisBuffer[inst->anaLen
                              @     - inst->blockLen10ms]
  cmp r3, r6
  mov r5, r3
  bge POST_LOOP_MEMCPY_1

  add r12, r3, r12, lsl #1    @ &inst->analysisBuffer[inst->blockLen10ms]

LOOP_MEMCPY_1:
  vld1.16 {q10, q11}, [r12]!  @ inst->analysisBuffer[i + inst->blockLen10ms]
  vst1.16 {q10, q11}, [r5]!   @ inst->analysisBuffer[i]
  cmp r5, r6
  blt LOOP_MEMCPY_1

POST_LOOP_MEMCPY_1:
  add r12, r3, r4, lsl #1     @ &inst->analysisBuffer[inst->anaLen]
  cmp r5, r12
  bge POST_LOOP_MEMCPY_2

LOOP_MEMCPY_2:
  vld1.16 {q10, q11}, [r2]!   @ new_speech[i]
  vst1.16 {q10, q11}, [r5]!   @ inst->analysisBuffer[
                              @     i + inst->anaLen - inst->blockLen10ms]
  cmp r5, r12
  blt LOOP_MEMCPY_2

POST_LOOP_MEMCPY_2:
  add r4, r1, r4, lsl #1      @ &out[inst->anaLen]
  cmp r1, r4
  ldr r2, [r0, #offset_nsx_window]            @ &inst->window[0]
  bge POST_LOOP_WINDOW_DATA

LOOP_WINDOW_DATA:
  vld1.16 {d4, d5}, [r3]!     @ inst->analysisBuffer[]
  vld1.16 {d6, d7}, [r2]!     @ inst->window[]
  vmull.s16 q0, d4, d6
  vmull.s16 q1, d5, d7
  vrshrn.i32 d4, q0, #14
  vrshrn.i32 d5, q1, #14
  vst1.16 {d4, d5}, [r1]!     @ out[]
  cmp r1, r4
  blt LOOP_WINDOW_DATA

POST_LOOP_WINDOW_DATA:
  pop {r4-r6}
  bx r14
.fnend

@ void CreateComplexBufferNeon(NsxInst_t* inst, int16_t* in, int16_t* out);
WebRtcNsx_CreateComplexBufferNeon:
.fnstart
  movw r3, #offset_nsx_anaLen
  movw r12, #offset_nsx_normData
  ldrsh r3, [r0, r3]                  @ inst->anaLen
  ldr r12, [r0, r12]                  @ inst->normData
  add r3, r1, r3, lsl #1              @ &in[inst->anaLen]

  vmov.i16 d7, #0                     @ For writing to imaginary parts.
  vmov.i16 d5, #0                     @ For writing to imaginary parts.
  vdup.i16 q10, r12

LOOP_CREATE_COMPLEX_BUFFER:           @ Unrolled by 16.
  vld1.16 {d0, d1, d2, d3}, [r1]!     @ in[]
  cmp r1, r3
  vshl.s16 q0, q10
  vshl.s16 q1, q10
  vmov d4, d1
  vmov d1, d5
  vmov d6, d3
  vmov d3, d7
  vst2.16 {d0, d1}, [r2]!
  vst2.16 {d4, d5}, [r2]!
  vst2.16 {d2, d3}, [r2]!
  vst2.16 {d6, d7}, [r2]!
  blt LOOP_CREATE_COMPLEX_BUFFER

  bx r14
.fnend
