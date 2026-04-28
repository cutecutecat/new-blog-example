const DEFAULT_WPM = 220;
const DEFAULT_CJK_CPM = 500;

type ReadingTimeOptions = {
	wpm?: number;
	cjkCpm?: number;
};

export function estimateReadingTime(
	text: string,
	options: ReadingTimeOptions = {},
) {
	const { wpm = DEFAULT_WPM, cjkCpm = DEFAULT_CJK_CPM } = options;
	const cleaned = toPlainText(text);

	const latinWordCount = cleaned.match(/\b[\w'-]+\b/g)?.length ?? 0;
	const cjkCharCount =
		cleaned.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/gu)
			?.length ?? 0;

	const minutes =
		latinWordCount / Math.max(1, wpm) + cjkCharCount / Math.max(1, cjkCpm);

	return {
		latinWordCount,
		cjkCharCount,
		minutes: Math.max(1, Math.ceil(minutes)),
	};
}

export function formatReadTime(minutes: number) {
	return `${minutes} min read`;
}

function toPlainText(markdown: string) {
	return markdown
		.replace(/```[\s\S]*?```/g, ' ')
		.replace(/`[^`]*`/g, ' ')
		.replace(/!\[[^\]]*]\([^)]*\)/g, ' ')
		.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
		.replace(/<[^>]+>/g, ' ')
		.replace(/^>\s+/gm, ' ')
		.replace(/[#*_~\-]+/g, ' ')
		.replace(/\s+/g, ' ')
		.trim();
}
