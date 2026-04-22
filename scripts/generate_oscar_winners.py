#!/usr/bin/env python3
"""
One-shot: resolve every Academy Award Best Picture winner to its TMDB id
and emit a Dart const for lib/utils/oscar_winners.dart.

TMDB's `oscar-winning-film` keyword (id 210024) is dominated by films
that only won technical / animated categories, so combining it with
genre+year filters routinely returns zero. A curated list sidesteps
that entirely — Best Picture is a finite, well-defined set.

Run once with a TMDB v3 api key; commit the generated Dart file.

    TMDB_API_KEY=... python3 scripts/generate_oscar_winners.py
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request

# (Year of ceremony, title as printed).  Year = release year.
# Source: Wikipedia "Academy Award for Best Picture" (1927/28 – 2024).
BEST_PICTURE = [
    (1927, "Wings"),
    (1928, "The Broadway Melody"),
    (1930, "All Quiet on the Western Front"),
    (1931, "Cimarron"),
    (1932, "Grand Hotel"),
    (1933, "Cavalcade"),
    (1934, "It Happened One Night"),
    (1935, "Mutiny on the Bounty"),
    (1936, "The Great Ziegfeld"),
    (1937, "The Life of Emile Zola"),
    (1938, "You Can't Take It with You"),
    (1939, "Gone with the Wind"),
    (1940, "Rebecca"),
    (1941, "How Green Was My Valley"),
    (1942, "Mrs. Miniver"),
    (1942, "Casablanca"),
    (1944, "Going My Way"),
    (1945, "The Lost Weekend"),
    (1946, "The Best Years of Our Lives"),
    (1947, "Gentleman's Agreement"),
    (1948, "Hamlet"),
    (1949, "All the King's Men"),
    (1950, "All About Eve"),
    (1951, "An American in Paris"),
    (1952, "The Greatest Show on Earth"),
    (1953, "From Here to Eternity"),
    (1954, "On the Waterfront"),
    (1955, "Marty"),
    (1956, "Around the World in 80 Days"),
    (1957, "The Bridge on the River Kwai"),
    (1958, "Gigi"),
    (1959, "Ben-Hur"),
    (1960, "The Apartment"),
    (1961, "West Side Story"),
    (1962, "Lawrence of Arabia"),
    (1963, "Tom Jones"),
    (1964, "My Fair Lady"),
    (1965, "The Sound of Music"),
    (1966, "A Man for All Seasons"),
    (1967, "In the Heat of the Night"),
    (1968, "Oliver!"),
    (1969, "Midnight Cowboy"),
    (1970, "Patton"),
    (1971, "The French Connection"),
    (1972, "The Godfather"),
    (1973, "The Sting"),
    (1974, "The Godfather Part II"),
    (1975, "One Flew Over the Cuckoo's Nest"),
    (1976, "Rocky"),
    (1977, "Annie Hall"),
    (1978, "The Deer Hunter"),
    (1979, "Kramer vs. Kramer"),
    (1980, "Ordinary People"),
    (1981, "Chariots of Fire"),
    (1982, "Gandhi"),
    (1983, "Terms of Endearment"),
    (1984, "Amadeus"),
    (1985, "Out of Africa"),
    (1986, "Platoon"),
    (1987, "The Last Emperor"),
    (1988, "Rain Man"),
    (1989, "Driving Miss Daisy"),
    (1990, "Dances with Wolves"),
    (1991, "The Silence of the Lambs"),
    (1992, "Unforgiven"),
    (1993, "Schindler's List"),
    (1994, "Forrest Gump"),
    (1995, "Braveheart"),
    (1996, "The English Patient"),
    (1997, "Titanic"),
    (1998, "Shakespeare in Love"),
    (1999, "American Beauty"),
    (2000, "Gladiator"),
    (2001, "A Beautiful Mind"),
    (2002, "Chicago"),
    (2003, "The Lord of the Rings: The Return of the King"),
    (2004, "Million Dollar Baby"),
    (2005, "Crash"),
    (2006, "The Departed"),
    (2007, "No Country for Old Men"),
    (2008, "Slumdog Millionaire"),
    (2009, "The Hurt Locker"),
    (2010, "The King's Speech"),
    (2011, "The Artist"),
    (2012, "Argo"),
    (2013, "12 Years a Slave"),
    (2014, "Birdman"),
    (2015, "Spotlight"),
    (2016, "Moonlight"),
    (2017, "The Shape of Water"),
    (2018, "Green Book"),
    (2019, "Parasite"),
    (2020, "Nomadland"),
    (2021, "CODA"),
    (2022, "Everything Everywhere All at Once"),
    (2023, "Oppenheimer"),
    (2024, "Anora"),
]


def tmdb_get(path, api_key, params=None):
    p = dict(params or {})
    p["api_key"] = api_key
    url = f"https://api.themoviedb.org/3{path}?{urllib.parse.urlencode(p)}"
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.loads(r.read().decode())


def find(title, year, api_key):
    """Find the best matching TMDB movie for (title, year).

    TMDB's `release_date` often differs from ceremony year by ±1
    (e.g. Casablanca: ceremony 1942, TMDB 1943). So we search without
    the year filter and pick the closest year match on exact title.
    """
    res = tmdb_get("/search/movie", api_key, {"query": title})
    hits = res.get("results", [])
    exact = [h for h in hits if h.get("title", "").lower() == title.lower()]
    pool = exact if exact else hits
    if not pool:
        return None

    def hit_year(h):
        d = h.get("release_date") or ""
        return int(d[:4]) if len(d) >= 4 and d[:4].isdigit() else 0

    # Closest year to target, tie-break by popularity (TMDB sorts that way).
    pool.sort(key=lambda h: (abs(hit_year(h) - year), -h.get("popularity", 0)))
    return pool[0]


def fetch_details(tmdb_id, api_key):
    return tmdb_get(
        f"/movie/{tmdb_id}",
        api_key,
        {"append_to_response": "external_ids"},
    )


def main():
    api_key = os.environ.get("TMDB_API_KEY")
    if not api_key:
        print("TMDB_API_KEY env var required", file=sys.stderr)
        return 1

    resolved = []
    missing = []

    for year, title in BEST_PICTURE:
        try:
            hit = find(title, year, api_key)
            if not hit:
                missing.append((year, title))
                continue
            tmdb_id = hit["id"]
            details = fetch_details(tmdb_id, api_key)
            genre_names = [g["name"] for g in details.get("genres", [])]
            imdb = (details.get("external_ids") or {}).get("imdb_id") or ""
            runtime = details.get("runtime") or 0
            poster = details.get("poster_path") or ""
            overview = details.get("overview") or ""
            resolved.append({
                "tmdb_id": tmdb_id,
                "imdb_id": imdb,
                "title": details.get("title") or title,
                "year": year,
                "genres": genre_names,
                "runtime": runtime,
                "poster_path": poster,
                "overview": overview,
            })
            print(f"  {year}  {details.get('title')}  (tmdb={tmdb_id})")
            time.sleep(0.05)  # polite pacing
        except Exception as e:
            missing.append((year, title, str(e)))

    if missing:
        print("\nMISSING:", missing, file=sys.stderr)

    # Emit Dart source.
    out = []
    out.append("// GENERATED by scripts/generate_oscar_winners.py — do not edit by hand.")
    out.append("// Source: Wikipedia 'Academy Award for Best Picture', resolved via TMDB search.")
    out.append("// Rerun annually after the next ceremony and re-commit.")
    out.append("")
    out.append("class OscarWinner {")
    out.append("  final int tmdbId;")
    out.append("  final String imdbId;")
    out.append("  final String title;")
    out.append("  final int year;")
    out.append("  final List<String> genres;")
    out.append("  final int runtime;")
    out.append("  final String posterPath;")
    out.append("  final String overview;")
    out.append("")
    out.append("  const OscarWinner({")
    out.append("    required this.tmdbId,")
    out.append("    required this.imdbId,")
    out.append("    required this.title,")
    out.append("    required this.year,")
    out.append("    required this.genres,")
    out.append("    required this.runtime,")
    out.append("    required this.posterPath,")
    out.append("    required this.overview,")
    out.append("  });")
    out.append("}")
    out.append("")
    out.append("/// Academy Award for Best Picture winners, 1927–present.")
    out.append("/// Used by the Home screen's Oscar-winners filter — baked client-side")
    out.append("/// because TMDB's `oscar-winning-film` keyword (210024) is overwhelmingly")
    out.append("/// tagged with titles that won technical/animated categories, not Best")
    out.append("/// Picture, so combining it with genre+year filters returns near-zero.")
    out.append("const kBestPictureWinners = <OscarWinner>[")
    for w in resolved:
        genres = ", ".join(f"'{g}'" for g in w["genres"])
        title = w["title"].replace("'", r"\'")
        overview = w["overview"].replace("'", r"\'").replace("\n", " ").replace("$", r"\$")
        out.append("  OscarWinner(")
        out.append(f"    tmdbId: {w['tmdb_id']},")
        out.append(f"    imdbId: '{w['imdb_id']}',")
        out.append(f"    title: '{title}',")
        out.append(f"    year: {w['year']},")
        out.append(f"    genres: [{genres}],")
        out.append(f"    runtime: {w['runtime']},")
        out.append(f"    posterPath: '{w['poster_path']}',")
        out.append(f"    overview: '{overview}',")
        out.append("  ),")
    out.append("];")

    with open("lib/utils/oscar_winners.dart", "w") as f:
        f.write("\n".join(out) + "\n")

    print(f"\nWrote {len(resolved)} winners to lib/utils/oscar_winners.dart")
    if missing:
        print(f"({len(missing)} missing; check log above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
