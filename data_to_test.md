| name | position | playcount | imdb | last_played | Started | Watched | Paused | Verified |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jumanji Welcome to the Jungle | 0 | 2 | tt2283362 | 2018-03-28 | Started | Watched | Paused | Yes |
| The Thousand Faces of Dunjia | 687 | 0 | tt6814080 | 2018-04-19 | Not Started | Not Watched | Stopped | Yes |
| Wonder Woman (0) | 5359 | 1 | tt0451279 | 2018-03-12 | Started | Watched | Paused | Yes |
| Wonder Woman (2017) | 7109 | 0 | tt0451279 | 2017-09-30 | Started | Not Watched | Paused  | No |
| Yamakasi | 0 | 0 | tt0267129 | | Not Started | Not Watched | Stopped  | Yes |
| Thor The Dark World | 946 | 1 | tt1981115 | 2018-03-15 | Started | Watched | Paused | Yes |


## ToDo List
- Movies
  - figure out how to handle duplicates
  - figure out how unseen and not started movies are dealt with
  - test multi-part movie is handled in a sane manner
  - tess imdb functionality to ensure metadata is in place
  - load entire movie history
- Handle TV Series
  - A seen episode marks the season as seen and the show as seen
  - test multi-ep series
  - created_at for season  and series = when first episode was ever watched, last_viewed_atand updated_at = when last episdewas watched
  - index = ep no, parent index = season number
- video nodes
- Does it work with anidb metadata
