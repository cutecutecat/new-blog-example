export type Author = {
	id: string;
	name: string;
	github: string;
	profileUrl: string;
	avatarUrl: string;
};

type AuthorSeed = {
	name: string;
	github: string;
};

const AUTHOR_AVATAR_SIZE = 48;

const AUTHOR_SEEDS: Record<string, AuthorSeed> = {
	vectorchord: {
		name: 'TensorChord',
		github: 'tensorchord',
	},
	openai: {
		name: 'OpenAI',
		github: 'openai',
	},
};

function buildGithubProfileUrl(username: string) {
	return `https://github.com/${username}`;
}

function buildGithubAvatarUrl(username: string, size = AUTHOR_AVATAR_SIZE) {
	return `https://github.com/${username}.png?size=${size}`;
}

export function getAuthor(authorId: string): Author {
	const normalizedId = authorId.trim().toLowerCase();
	const seed = AUTHOR_SEEDS[normalizedId];

	if (seed) {
		return {
			id: normalizedId,
			name: seed.name,
			github: seed.github,
			profileUrl: buildGithubProfileUrl(seed.github),
			avatarUrl: buildGithubAvatarUrl(seed.github),
		};
	}

	return {
		id: normalizedId,
		name: authorId,
		github: normalizedId,
		profileUrl: buildGithubProfileUrl(normalizedId),
		avatarUrl: buildGithubAvatarUrl(normalizedId),
	};
}
