#!/usr/bin/env python3
"""
Resolves all award-winner title lists to TMDB metadata in a single pass and
emits lib/utils/oscar_winners.dart with constants for every supported award:

  - kBestPictureWinners  (Academy Best Picture; full coverage 1927–present)
  - kPalmeDorWinners     (Cannes; full coverage 1955–present)
  - kBaftaBestFilmWinners (BAFTA Best Film; 1990–present + pre-90s classics)
  - kGoldenGlobeDramaWinners      (1990–present)
  - kGoldenGlobeMusicalComedyWinners (1990–present)
  - kAnyAwardWinners     (deduped union — backs the "Any award" filter)

Single TMDB resolution pass deduped by (title, year) so a film that won
multiple awards is fetched once.

    TMDB_API_KEY=... python3 scripts/generate_award_winners.py
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request

# Best Picture (Academy) — ceremony year, title.
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

# Cannes Palme d'Or — full list 1955–present (ties included).
PALME_DOR = [
    (1955, "Marty"),
    (1956, "The Silent World"),
    (1957, "Friendly Persuasion"),
    (1958, "The Cranes Are Flying"),
    (1959, "Black Orpheus"),
    (1960, "La Dolce Vita"),
    (1961, "Viridiana"),
    (1961, "The Long Absence"),
    (1962, "The Given Word"),
    (1963, "The Leopard"),
    (1964, "The Umbrellas of Cherbourg"),
    (1965, "The Knack ...and How to Get It"),
    (1966, "A Man and a Woman"),
    (1966, "The Birds, the Bees and the Italians"),
    (1967, "Blow-Up"),
    (1969, "If...."),
    (1970, "MASH"),
    (1971, "The Go-Between"),
    (1972, "The Mattei Affair"),
    (1972, "The Working Class Goes to Heaven"),
    (1973, "The Hireling"),
    (1973, "Scarecrow"),
    (1974, "The Conversation"),
    (1975, "Chronicle of the Years of Fire"),
    (1976, "Taxi Driver"),
    (1977, "Padre Padrone"),
    (1978, "The Tree of Wooden Clogs"),
    (1979, "Apocalypse Now"),
    (1979, "The Tin Drum"),
    (1980, "All That Jazz"),
    (1980, "Kagemusha"),
    (1981, "Man of Iron"),
    (1982, "Missing"),
    (1982, "Yol"),
    (1983, "The Ballad of Narayama"),
    (1984, "Paris, Texas"),
    (1985, "When Father Was Away on Business"),
    (1986, "The Mission"),
    (1987, "Under the Sun of Satan"),
    (1988, "Pelle the Conqueror"),
    (1989, "Sex, Lies, and Videotape"),
    (1990, "Wild at Heart"),
    (1991, "Barton Fink"),
    (1992, "The Best Intentions"),
    (1993, "The Piano"),
    (1993, "Farewell My Concubine"),
    (1994, "Pulp Fiction"),
    (1995, "Underground"),
    (1996, "Secrets & Lies"),
    (1997, "The Eel"),
    (1997, "Taste of Cherry"),
    (1998, "Eternity and a Day"),
    (1999, "Rosetta"),
    (2000, "Dancer in the Dark"),
    (2001, "The Son's Room"),
    (2002, "The Pianist"),
    (2003, "Elephant"),
    (2004, "Fahrenheit 9/11"),
    (2005, "L'Enfant"),
    (2006, "The Wind That Shakes the Barley"),
    (2007, "4 Months, 3 Weeks and 2 Days"),
    (2008, "The Class"),
    (2009, "The White Ribbon"),
    (2010, "Uncle Boonmee Who Can Recall His Past Lives"),
    (2011, "The Tree of Life"),
    (2012, "Amour"),
    (2013, "Blue Is the Warmest Colour"),
    (2014, "Winter Sleep"),
    (2015, "Dheepan"),
    (2016, "I, Daniel Blake"),
    (2017, "The Square"),
    (2018, "Shoplifters"),
    (2019, "Parasite"),
    (2021, "Titane"),
    (2022, "Triangle of Sadness"),
    (2023, "Anatomy of a Fall"),
    (2024, "Anora"),
]

# BAFTA Best Film — 1990–present plus pre-90s classics where they
# differed from Best Picture (avoid pure repeats of films already in BP).
BAFTA_BEST_FILM = [
    # Pre-1990 selected
    (1947, "The Best Years of Our Lives"),
    (1962, "Lawrence of Arabia"),
    (1963, "Tom Jones"),
    (1966, "A Man for All Seasons"),
    (1969, "Midnight Cowboy"),
    (1970, "Butch Cassidy and the Sundance Kid"),
    (1971, "Sunday Bloody Sunday"),
    (1972, "Cabaret"),
    (1973, "Day for Night"),
    (1975, "Alice Doesn't Live Here Anymore"),
    (1976, "One Flew Over the Cuckoo's Nest"),
    (1977, "Annie Hall"),
    (1978, "Julia"),
    (1979, "Manhattan"),
    (1980, "The Elephant Man"),
    (1981, "Chariots of Fire"),
    (1982, "Gandhi"),
    (1983, "Educating Rita"),
    (1984, "The Killing Fields"),
    (1985, "The Purple Rose of Cairo"),
    (1986, "A Room with a View"),
    (1987, "Jean de Florette"),
    (1988, "The Last Emperor"),
    (1989, "Dead Poets Society"),
    # 1990+ full
    (1990, "Goodfellas"),
    (1991, "The Commitments"),
    (1992, "Howards End"),
    (1993, "Schindler's List"),
    (1994, "Four Weddings and a Funeral"),
    (1995, "Sense and Sensibility"),
    (1996, "The English Patient"),
    (1997, "The Full Monty"),
    (1998, "Shakespeare in Love"),
    (1999, "American Beauty"),
    (2000, "Gladiator"),
    (2001, "The Lord of the Rings: The Fellowship of the Ring"),
    (2002, "The Pianist"),
    (2003, "The Lord of the Rings: The Return of the King"),
    (2004, "The Aviator"),
    (2005, "Brokeback Mountain"),
    (2006, "The Queen"),
    (2007, "Atonement"),
    (2008, "Slumdog Millionaire"),
    (2009, "The Hurt Locker"),
    (2010, "The King's Speech"),
    (2011, "The Artist"),
    (2012, "Argo"),
    (2013, "12 Years a Slave"),
    (2014, "Boyhood"),
    (2015, "The Revenant"),
    (2016, "La La Land"),
    (2017, "Three Billboards Outside Ebbing, Missouri"),
    (2018, "Roma"),
    (2019, "1917"),
    (2020, "Nomadland"),
    (2021, "The Power of the Dog"),
    (2022, "All Quiet on the Western Front"),
    (2023, "Oppenheimer"),
]

# Golden Globe Best Motion Picture — Drama (1990–present)
GG_DRAMA = [
    (1990, "Dances with Wolves"),
    (1991, "Bugsy"),
    (1992, "Scent of a Woman"),
    (1993, "Schindler's List"),
    (1994, "Forrest Gump"),
    (1995, "Sense and Sensibility"),
    (1996, "The English Patient"),
    (1997, "Titanic"),
    (1998, "Saving Private Ryan"),
    (1999, "American Beauty"),
    (2000, "Gladiator"),
    (2001, "A Beautiful Mind"),
    (2002, "The Hours"),
    (2003, "The Lord of the Rings: The Return of the King"),
    (2004, "The Aviator"),
    (2005, "Brokeback Mountain"),
    (2006, "Babel"),
    (2007, "Atonement"),
    (2008, "Slumdog Millionaire"),
    (2009, "Avatar"),
    (2010, "The Social Network"),
    (2011, "The Descendants"),
    (2012, "Argo"),
    (2013, "12 Years a Slave"),
    (2014, "Boyhood"),
    (2015, "The Revenant"),
    (2016, "Moonlight"),
    (2017, "Three Billboards Outside Ebbing, Missouri"),
    (2018, "Bohemian Rhapsody"),
    (2019, "1917"),
    (2020, "Nomadland"),
    (2021, "The Power of the Dog"),
    (2022, "The Fabelmans"),
    (2023, "Oppenheimer"),
    (2024, "The Brutalist"),
]

# Golden Globe Best Motion Picture — Musical or Comedy (1990–present)
GG_MUSICAL_COMEDY = [
    (1990, "Green Card"),
    (1991, "Beauty and the Beast"),
    (1992, "The Player"),
    (1993, "Mrs. Doubtfire"),
    (1994, "The Lion King"),
    (1995, "Babe"),
    (1996, "Evita"),
    (1997, "As Good as It Gets"),
    (1998, "Shakespeare in Love"),
    (1999, "Toy Story 2"),
    (2000, "Almost Famous"),
    (2001, "Moulin Rouge!"),
    (2002, "Chicago"),
    (2003, "Lost in Translation"),
    (2004, "Sideways"),
    (2005, "Walk the Line"),
    (2006, "Dreamgirls"),
    (2007, "Sweeney Todd: The Demon Barber of Fleet Street"),
    (2008, "Vicky Cristina Barcelona"),
    (2009, "The Hangover"),
    (2010, "The Kids Are All Right"),
    (2011, "The Artist"),
    (2012, "Les Misérables"),
    (2013, "American Hustle"),
    (2014, "The Grand Budapest Hotel"),
    (2015, "The Martian"),
    (2016, "La La Land"),
    (2017, "Lady Bird"),
    (2018, "Green Book"),
    (2019, "Once Upon a Time in Hollywood"),
    (2020, "Borat Subsequent Moviefilm"),
    (2021, "West Side Story"),
    (2022, "The Banshees of Inisherin"),
    (2023, "Poor Things"),
    (2024, "Emilia Pérez"),
]


# Maps each list constant to its short award-tag used in the AwardWinner.
LISTS = [
    ("bestPicture", BEST_PICTURE),
    ("palmeDor", PALME_DOR),
    ("baftaBestFilm", BAFTA_BEST_FILM),
    ("goldenGlobeDrama", GG_DRAMA),
    ("goldenGlobeMusicalComedy", GG_MUSICAL_COMEDY),
]


def tmdb_get(path, api_key, params=None):
    p = dict(params or {})
    p["api_key"] = api_key
    url = f"https://api.themoviedb.org/3{path}?{urllib.parse.urlencode(p)}"
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.loads(r.read().decode())


def find(title, year, api_key):
    res = tmdb_get("/search/movie", api_key, {"query": title})
    hits = res.get("results", [])
    exact = [h for h in hits if h.get("title", "").lower() == title.lower()]
    pool = exact if exact else hits
    if not pool:
        return None

    def hit_year(h):
        d = h.get("release_date") or ""
        return int(d[:4]) if len(d) >= 4 and d[:4].isdigit() else 0

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

    # Manual TMDB id overrides for entries whose TMDB search consistently
    # resolves to the wrong film (titles with unusual punctuation, common
    # words that match unrelated obscure films, etc.). Verified against
    # /movie/{id} on TMDB before adding.
    overrides = {
        ("mash", 1970): 651,  # M*A*S*H (Robert Altman)
    }

    # Dedup by (title.lower(), year) — a film that wins multiple awards in
    # the SAME ceremony year only needs one TMDB lookup. Cross-year cases
    # (e.g. Best Picture 1975 vs BAFTA 1976 for the same film) are handled
    # by a second dedup pass on tmdb_id below.
    by_key = {}  # (title_lower, year) -> {meta, awards: set[str]}
    missing = []

    for award_tag, items in LISTS:
        for year, title in items:
            key = (title.lower(), year)
            if key in by_key:
                by_key[key]["awards"].add(award_tag)
                continue
            try:
                forced = overrides.get(key)
                if forced is not None:
                    tmdb_id = forced
                    details = fetch_details(tmdb_id, api_key)
                    hit = {"id": tmdb_id, "release_date": details.get("release_date") or ""}
                else:
                    hit = find(title, year, api_key)
                    if not hit:
                        missing.append((award_tag, year, title))
                        continue
                    tmdb_id = hit["id"]
                    details = fetch_details(tmdb_id, api_key)
                genre_names = [g["name"] for g in details.get("genres", [])]
                imdb = (details.get("external_ids") or {}).get("imdb_id") or ""
                runtime = details.get("runtime") or 0
                poster = details.get("poster_path") or ""
                overview = details.get("overview") or ""
                by_key[key] = {
                    "tmdb_id": tmdb_id,
                    "imdb_id": imdb,
                    "title": details.get("title") or title,
                    "year": year,
                    "genres": genre_names,
                    "runtime": runtime,
                    "poster_path": poster,
                    "overview": overview,
                    "awards": {award_tag},
                }
                print(f"  [{award_tag}] {year} {details.get('title')}  (tmdb={tmdb_id})")
                time.sleep(0.05)
            except Exception as e:
                missing.append((award_tag, year, title, str(e)))

    if missing:
        print("\nMISSING:", missing, file=sys.stderr)

    # Second-pass dedup by tmdb_id — merges entries that resolved to the
    # same film via different (title, year) keys. Common case: a film won
    # one award in year N and another in year N+1 (different ceremony
    # years for the same calendar release). Picks the earliest year as
    # the canonical year and unions the awards sets.
    by_tmdb = {}  # tmdb_id -> entry
    for entry in by_key.values():
        existing = by_tmdb.get(entry["tmdb_id"])
        if existing is None:
            by_tmdb[entry["tmdb_id"]] = entry
            continue
        existing["awards"] |= entry["awards"]
        if entry["year"] < existing["year"]:
            existing["year"] = entry["year"]

    resolved = sorted(by_tmdb.values(), key=lambda r: (r["year"], r["title"].lower()))

    out = []
    out.append(
        "// GENERATED by scripts/generate_award_winners.py — do not edit by hand."
    )
    out.append(
        "// Sources: Wikipedia ('Academy Award for Best Picture',"
    )
    out.append(
        "//   'Palme d''Or', 'BAFTA Award for Best Film',"
    )
    out.append(
        "//   'Golden Globe Award for Best Motion Picture – Drama',"
    )
    out.append(
        "//   'Golden Globe Award for Best Motion Picture – Musical or Comedy')."
    )
    out.append(
        "// Resolved via TMDB /search/movie + /movie/{id}?append_to_response=external_ids."
    )
    out.append(
        "// Rerun annually after the next ceremony round and re-commit."
    )
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
    out.append("  /// Which award tags this film won. Used by the per-category")
    out.append("  /// lookup helpers below + by the 'Any award' filter.")
    out.append("  final Set<String> awards;")
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
    out.append("    required this.awards,")
    out.append("  });")
    out.append("}")
    out.append("")
    out.append("typedef AwardWinner = OscarWinner;")
    out.append("")
    out.append("/// Master list — one entry per film. The per-category lists below")
    out.append("/// derive from this via `awards.contains('<tag>')`.")
    out.append("const _allAwardWinners = <OscarWinner>[")
    for w in resolved:
        genres = ", ".join(f"'{g}'" for g in w["genres"])
        title = w["title"].replace("'", r"\'")
        overview = (
            w["overview"].replace("'", r"\'").replace("\n", " ").replace("$", r"\$")
        )
        awards = ", ".join(f"'{a}'" for a in sorted(w["awards"]))
        out.append("  OscarWinner(")
        out.append(f"    tmdbId: {w['tmdb_id']},")
        out.append(f"    imdbId: '{w['imdb_id']}',")
        out.append(f"    title: '{title}',")
        out.append(f"    year: {w['year']},")
        out.append(f"    genres: [{genres}],")
        out.append(f"    runtime: {w['runtime']},")
        out.append(f"    posterPath: '{w['poster_path']}',")
        out.append(f"    overview: '{overview}',")
        out.append(f"    awards: {{{awards}}},")
        out.append("  ),")
    out.append("];")
    out.append("")
    out.append("List<OscarWinner> _byAward(String tag) =>")
    out.append("    _allAwardWinners.where((w) => w.awards.contains(tag)).toList(growable: false);")
    out.append("")
    out.append("/// Academy Award Best Picture winners, 1927–present.")
    out.append("final List<OscarWinner> kBestPictureWinners = _byAward('bestPicture');")
    out.append("")
    out.append("/// Cannes Palme d'Or winners, 1955–present.")
    out.append("final List<OscarWinner> kPalmeDorWinners = _byAward('palmeDor');")
    out.append("")
    out.append("/// BAFTA Best Film winners (selected pre-1990 + full 1990–present).")
    out.append(
        "final List<OscarWinner> kBaftaBestFilmWinners = _byAward('baftaBestFilm');"
    )
    out.append("")
    out.append("/// Golden Globe Best Motion Picture – Drama winners, 1990–present.")
    out.append(
        "final List<OscarWinner> kGoldenGlobeDramaWinners = _byAward('goldenGlobeDrama');"
    )
    out.append("")
    out.append(
        "/// Golden Globe Best Motion Picture – Musical or Comedy winners, 1990–present."
    )
    out.append(
        "final List<OscarWinner> kGoldenGlobeMusicalComedyWinners ="
    )
    out.append("    _byAward('goldenGlobeMusicalComedy');")
    out.append("")
    out.append("/// Deduped union — every film that won at least one supported award.")
    out.append("/// Backs the 'Any award' filter on Home.")
    out.append("const List<OscarWinner> kAnyAwardWinners = _allAwardWinners;")
    out.append("")
    out.append("enum AwardCategory {")
    out.append("  /// No award filter — show everything.")
    out.append("  none,")
    out.append("  /// Any supported award — union of all per-category lists.")
    out.append("  any,")
    out.append("  bestPicture,")
    out.append("  palmeDor,")
    out.append("  baftaBestFilm,")
    out.append("  goldenGlobeDrama,")
    out.append("  goldenGlobeMusicalComedy,")
    out.append("}")
    out.append("")
    out.append("extension AwardCategoryLabel on AwardCategory {")
    out.append("  String get label => switch (this) {")
    out.append("        AwardCategory.none => 'None',")
    out.append("        AwardCategory.any => 'Any award',")
    out.append("        AwardCategory.bestPicture => 'Best Picture',")
    out.append("        AwardCategory.palmeDor => 'Palme d\\'Or',")
    out.append("        AwardCategory.baftaBestFilm => 'BAFTA Best Film',")
    out.append("        AwardCategory.goldenGlobeDrama => 'Golden Globe — Drama',")
    out.append("        AwardCategory.goldenGlobeMusicalComedy =>")
    out.append("          'Golden Globe — Musical/Comedy',")
    out.append("      };")
    out.append("}")
    out.append("")
    out.append("/// Per-category lookup. `none` returns empty (no splice / no filter);")
    out.append("/// `any` returns the deduped union.")
    out.append("Map<AwardCategory, List<OscarWinner>> get kAwardWinners => {")
    out.append("      AwardCategory.none: const <OscarWinner>[],")
    out.append("      AwardCategory.any: kAnyAwardWinners,")
    out.append("      AwardCategory.bestPicture: kBestPictureWinners,")
    out.append("      AwardCategory.palmeDor: kPalmeDorWinners,")
    out.append("      AwardCategory.baftaBestFilm: kBaftaBestFilmWinners,")
    out.append("      AwardCategory.goldenGlobeDrama: kGoldenGlobeDramaWinners,")
    out.append("      AwardCategory.goldenGlobeMusicalComedy:")
    out.append("          kGoldenGlobeMusicalComedyWinners,")
    out.append("    };")

    with open("lib/utils/oscar_winners.dart", "w") as f:
        f.write("\n".join(out) + "\n")

    print(f"\nWrote {len(resolved)} unique winners to lib/utils/oscar_winners.dart")
    if missing:
        print(f"({len(missing)} missing; check log above)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
