import duckdb
import unicodedata

con = duckdb.connect(':memory:')

# Create NFC and NFD versions of "Cronología de Diseñadores"
nfc_text = unicodedata.normalize('NFC', 'Cronología de Diseñadores')
nfd_text = unicodedata.normalize('NFD', 'Cronología de Diseñadores')

con.execute('CREATE TABLE notes (title VARCHAR)')
con.execute('INSERT INTO notes VALUES (?)', [nfc_text])
con.execute('INSERT INTO notes VALUES (?)', [nfd_text])

# Regex that ignores combining characters: 
# cr[oóöOÓÖ]\p{M}*n[nñNÑ]\p{M}*[oóöOÓÖ]\p{M}*l[oóöOÓÖ]\p{M}*g[iíïIÍÏ]\p{M}*[aáäAÁÄ]\p{M}*
# Actually, if we just put \p{M}* after EVERY letter in our generated regex!

con.execute("SELECT title, title = ? AS is_nfc FROM notes WHERE regexp_matches(title, '(?i)d\p{M}*[iíïIÍÏ]\p{M}*s\p{M}*[eéëEÉË]\p{M}*[nñNÑ]\p{M}*[aáäAÁÄ]\p{M}*d\p{M}*[oóöOÓÖ]\p{M}*r\p{M}*[eéëEÉË]\p{M}*s\p{M}*')", [nfc_text])
res = con.fetchall()
print("Matches for 'diseñadores' with \p{M}*:")
for r in res:
    print(r)

