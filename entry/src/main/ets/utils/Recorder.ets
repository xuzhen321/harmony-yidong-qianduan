import { audio } from '@kit.AudioKit';

/**
 * 麦克风录音 → WAV。
 *
 * 为什么不用 AVRecorder：AVRecorder 输出的是 m4a/aac，后端只要
 * **16kHz / 16bit / 单声道 PCM WAV**（联调文档 1.4 节），转码太麻烦。
 * 所以直接用 AudioCapturer 抓原始 PCM，再自己拼 44 字节 WAV 头 —— 拿到什么就传什么，
 * 不做任何重采样，正好符合后端"不做重采样"的要求。
 *
 * 取数据用的是 `on('readData')` 事件（`read()` 从 API 11 起已废弃）。
 */

/** 采样率：后端固定 16000 Hz */
const SAMPLE_RATE: number = 16000;
/** 声道数：单声道 */
const CHANNELS: number = 1;
/** 位深：16 bit 小端 */
const BITS_PER_SAMPLE: number = 16;
/** 16bit = 2 字节 */
const BYTES_PER_SAMPLE: number = BITS_PER_SAMPLE / 8;
/** 每秒字节数：16000 * 2 * 1 = 32000 */
const BYTES_PER_SECOND: number = SAMPLE_RATE * BYTES_PER_SAMPLE * CHANNELS;
/** WAV 文件头固定 44 字节 */
const WAV_HEADER_SIZE: number = 44;
/** 轮询间隔：每 50ms 看一次攒够没有 */
const POLL_MS: number = 50;

export interface RecordedWav {
  /** 带 44 字节文件头的完整 WAV，直接拿来当 multipart 的 audio */
  wav: ArrayBuffer;
  /** 纯 PCM 数据字节数 */
  pcmBytes: number;
  /** 实际录到的时长（毫秒） */
  durationMs: number;
}

/** 简单延时，只用来轮询录音进度 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 录一段固定时长的音频。
 *
 * @param durationMs 要录多久，文档要求 0.5~1.5 秒
 */
export async function recordWav(durationMs: number): Promise<RecordedWav> {
  // 录音是设备相关的系统能力，先判断一下，顺便让编译器知道这里做过 syscap 检查
  if (canIUse('SystemCapability.Multimedia.Audio.Core') &&
    canIUse('SystemCapability.Multimedia.Audio.Capturer')) {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: SAMPLE_RATE,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };

    const capturer: audio.AudioCapturer = await audio.createAudioCapturer(options);

    const targetBytes: number = Math.floor((SAMPLE_RATE * durationMs) / 1000) * BYTES_PER_SAMPLE * CHANNELS;
    const chunks: ArrayBuffer[] = [];
    let total: number = 0;

    // readData 回调里的 buffer 可能会被系统复用，必须当场拷一份
    const onData = (buffer: ArrayBuffer): void => {
      if (!buffer || buffer.byteLength === 0) {
        return;
      }
      const remain: number = targetBytes - total;
      if (remain <= 0) {
        return;
      }
      const take: number = buffer.byteLength <= remain ? buffer.byteLength : remain;
      const copy: ArrayBuffer = buffer.slice(0, take);
      chunks.push(copy);
      total = total + copy.byteLength;
    };

    try {
      bindReadData(capturer, onData);
      await capturer.start();

      // 攒够 durationMs 对应的字节数就停；deadline 是兜底，别让界面卡死
      const deadline: number = Date.now() + durationMs + 3000;
      while (total < targetBytes && Date.now() < deadline) {
        await delay(POLL_MS);
      }
    } finally {
      // 不管成功失败都要停掉并释放，否则下次 createAudioCapturer 会拿不到麦克风
      try {
        capturer.off('readData', onData);
      } catch (err) {
        console.warn(`解绑录音回调失败: ${JSON.stringify(err)}`);
      }
      try {
        await capturer.stop();
      } catch (err) {
        console.warn(`停止录音失败: ${JSON.stringify(err)}`);
      }
      try {
        await capturer.release();
      } catch (err) {
        console.warn(`释放录音器失败: ${JSON.stringify(err)}`);
      }
    }

    // 把分块攒到的 PCM 拼成一块
    const pcm: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      const view: Uint8Array = new Uint8Array(chunks[i]);
      pcm.set(view, offset);
      offset = offset + view.length;
    }

    const actualMs: number = total > 0 ? Math.round((total * 1000) / BYTES_PER_SECOND) : 0;
    return {
      wav: buildWav(pcm),
      pcmBytes: total,
      durationMs: actualMs
    };
  }

  throw new Error('当前设备不支持录音（缺少系统音频能力）');
}

/** 注册 readData 回调。`on()` 声明了可能抛异常，这里包一层，调用方只管业务 */
function bindReadData(capturer: audio.AudioCapturer, onData: (buffer: ArrayBuffer) => void): void {
  try {
    capturer.on('readData', onData); // 一旦有新数据,则使用onData处理函数
  } catch (err) {
    throw new Error(`注册录音回调失败：${JSON.stringify(err)}`);
  }
}

/** 拼 44 字节 RIFF/WAVE 文件头 + PCM 数据 */
function buildWav(pcm: Uint8Array): ArrayBuffer {
  const dataSize: number = pcm.length;
  const buffer: ArrayBuffer = new ArrayBuffer(WAV_HEADER_SIZE + dataSize);
  const view: DataView = new DataView(buffer);

  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true); // 文件长度 - 8
  writeAscii(view, 8, 'WAVE');


  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true); // fmt 块长度
  view.setUint16(20, 1, true); // 1 = PCM
  view.setUint16(22, CHANNELS, true);
  view.setUint32(24, SAMPLE_RATE, true);
  view.setUint32(28, BYTES_PER_SECOND, true); // 每秒字节数
  view.setUint16(32, CHANNELS * BYTES_PER_SAMPLE, true); // 块对齐
  view.setUint16(34, BITS_PER_SAMPLE, true);


  writeAscii(view, 36, 'data');
  view.setUint32(40, dataSize, true);

  new Uint8Array(buffer).set(pcm, WAV_HEADER_SIZE);
  return buffer;
}

/** 把 ASCII 字符串写进 DataView（RIFF 的四个标记） */
function writeAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i++) {
    view.setUint8(offset + i, text.charCodeAt(i));
  }
}
