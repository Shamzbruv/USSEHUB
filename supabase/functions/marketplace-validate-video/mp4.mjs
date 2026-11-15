const MAX_SECONDS = 15;
const MAX_BYTES = 20 * 1024 * 1024;

export function miniAdDuration(bytes) {
    if (!bytes.byteLength || bytes.byteLength > MAX_BYTES) throw new Error('Choose an MP4 up to 20 MB.');
    const view = new DataView(bytes);
    const tag = offset => String.fromCharCode(...new Uint8Array(bytes, offset, 4));
    const invalid = () => { throw new Error('Export a standard H.264 MP4 with AAC audio, then try again.'); };
    let inspected = 0;

    function boxes(start, end) {
        const list = [];
        for (let offset = start; offset < end;) {
            if (++inspected > 2000 || end - offset < 8) invalid();
            let size = view.getUint32(offset);
            const type = tag(offset + 4);
            let header = 8;
            if (size === 1) {
                if (end - offset < 16) invalid();
                size = Number(view.getBigUint64(offset + 8));
                header = 16;
            } else if (size === 0) {
                size = end - offset;
            }
            if (size < header || size > end - offset) invalid();
            list.push({ type, start: offset + header, end: offset + size });
            offset += size;
        }
        return list;
    }

    function first(list, type) {
        const matches = list.filter(box => box.type === type);
        if (matches.length !== 1) invalid();
        return matches[0];
    }

    function timeHeader(box) {
        if (box.end - box.start < 20) invalid();
        const version = view.getUint8(box.start);
        if (version !== 0 && version !== 1) invalid();
        if (version === 1 && box.end - box.start < 32) invalid();
        const offset = box.start + (version === 1 ? 20 : 12);
        const scale = view.getUint32(offset);
        const duration = version === 1 ? Number(view.getBigUint64(offset + 4)) : view.getUint32(offset + 4);
        if (!scale || !duration || !Number.isSafeInteger(duration)) invalid();
        return { seconds: duration / scale, scale };
    }

    const top = boxes(0, bytes.byteLength);
    first(top, 'ftyp');
    if (!top.some(box => box.type === 'mdat' && box.end > box.start) || top.some(box => box.type === 'moof')) invalid();
    const movie = first(top, 'moov');
    const movieBoxes = boxes(movie.start, movie.end);
    if (movieBoxes.some(box => box.type === 'mvex')) invalid();
    const movieTime = timeHeader(first(movieBoxes, 'mvhd'));
    let duration = movieTime.seconds;
    let video = false;

    for (const track of movieBoxes.filter(box => box.type === 'trak')) {
        const trackBoxes = boxes(track.start, track.end);
        const trackHeader = first(trackBoxes, 'tkhd');
        const version = view.getUint8(trackHeader.start);
        if (version !== 0 && version !== 1) invalid();
        const timeOffset = trackHeader.start + (version === 1 ? 28 : 20);
        if (timeOffset + (version === 1 ? 8 : 4) > trackHeader.end) invalid();
        const trackDuration = version === 1 ? Number(view.getBigUint64(timeOffset)) : view.getUint32(timeOffset);
        duration = Math.max(duration, trackDuration / movieTime.scale);

        const media = first(trackBoxes, 'mdia');
        const mediaBoxes = boxes(media.start, media.end);
        const handler = first(mediaBoxes, 'hdlr');
        if (handler.end - handler.start < 12) invalid();
        const kind = tag(handler.start + 8);
        if (kind !== 'vide' && kind !== 'soun') invalid();
        if (kind === 'vide') video = true;
        const mediaTime = timeHeader(first(mediaBoxes, 'mdhd'));
        const mediaInfo = first(mediaBoxes, 'minf');
        const sampleTable = first(boxes(mediaInfo.start, mediaInfo.end), 'stbl');
        const sampleBoxes = boxes(sampleTable.start, sampleTable.end);
        const descriptions = first(sampleBoxes, 'stsd');
        if (descriptions.end - descriptions.start < 8) invalid();
        const codecs = boxes(descriptions.start + 8, descriptions.end).map(box => box.type);
        if (codecs.length !== 1 || !(kind === 'vide' ? ['avc1','avc3'] : ['mp4a']).includes(codecs[0])) invalid();
        const times = first(sampleBoxes, 'stts');
        if (times.end - times.start < 8) invalid();
        const entries = view.getUint32(times.start + 4);
        if (!entries || entries > 10000 || times.start + 8 + entries * 8 !== times.end) invalid();
        let ticks = 0;
        for (let offset = times.start + 8; offset < times.end; offset += 8) {
            ticks += view.getUint32(offset) * view.getUint32(offset + 4);
        }
        // AAC may have an encoder padding frame outside the presentation time.
        const allowedMediaTime = MAX_SECONDS + (kind === 'soun' ? 0.05 : 0);
        if (!ticks || Math.max(ticks / mediaTime.scale, mediaTime.seconds) > allowedMediaTime) {
            throw new Error('Mini-ads can be at most 15 seconds long.');
        }
    }
    if (!video) invalid();
    if (!(duration > 0 && duration <= MAX_SECONDS)) throw new Error('Mini-ads can be at most 15 seconds long.');
    return Math.ceil(duration * 1000);
}
