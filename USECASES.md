# Use cases

This is a log of what Servant actually does for me, not a roadmap. Everything
listed here runs today. Things I have built but do not use yet are not in this
file.

The order matters. The first group is what no hosted assistant can ever do. The
second is what no vendor has a reason to build. The third is unremarkable on its
own and exists so the first two can be queried together.

## 1. What cannot leave this machine

These are not preferences for privacy. They are data I would never paste into a
hosted model, which makes local inference the only option rather than the
principled one.

**Health records for a family member.**
Vaccinations, symptoms, appointments, questions to ask at the next visit.
_since ____ · replaces _____

**Bank transactions and expense analysis.**
Categorisation and drift over full history. Fetched through Enable Banking
(PSD2), with CSV import as the fallback path when consent expires.
_since ____ · replaces _____

**Personal habit tracking.**
Commits, routines, consumption. Low value per entry, useful only in aggregate
and only over long periods.
_since ____ · replaces _____

## 2. What nobody else will build for me

The audience for each of these is exactly one person. That is why they do not
exist as products, and why an assistant that generates its own interfaces beats
a catalogue of apps.

**Matcha vendor notes.**
Producer, cultivar, harvest, tasting notes, where to reorder from and with what
shipping delay.
_since ____ · replaces _____

**Wine maker notes.**
Same shape, different schema. Region, cuvée, vintage, who imports it.
_since ____ · replaces _____

**Checklists.**
Recurring procedures I refuse to re-derive every time.
_since ____ · replaces _____

## 3. The substrate

None of this is interesting and all of it is table stakes. It is here because a
question worth asking usually spans two of these sources, and because a missing
calendar disqualifies an assistant even though a present one convinces nobody.

Servant does not reimplement any of it. It reads standard protocols and
self-hosted services, which is the only reason this layer is affordable.

- **Contacts and calendar.** CalDAV and CardDAV clients, synced with my phone.
- **Birthdays.** The `BDAY` field of the contacts I already keep. Not a feature,
  a query.
- **Photo backup with tags.** Handled by a dedicated service; Servant reads it.

## 4. What it is all for

The point is not any single item above. It is the questions that only become
answerable once they share one timeline, and that no application can ship
because nobody knows them in advance:

> Have my matcha expenses drifted since the trip?

> Do the weeks with the most meetings show fewer commits?

Neither question was designed for. Both were asked once, casually, and answered
correctly against real data. That is the whole argument.

---

_Maintenance: one line per entry, added the day the use case actually starts.
The `replaces` field is the one that matters later; a capability is a claim, a
replaced habit is evidence._
