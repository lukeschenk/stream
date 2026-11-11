<script lang="ts">
	import WeeklyPublication from './WeeklyPublication.svelte';
	let { data } = $props();
</script>

<svelte:head>
	<title>Stream Weekly - Five films worth your time</title>
	<meta
		name="description"
		content="Five films worth your time."
	/>
</svelte:head>

<WeeklyPublication
	movies={data.movies}
	selection={data.selection}
	archive={data.archive}
/>
