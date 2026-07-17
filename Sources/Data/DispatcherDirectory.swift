import Foundation

/// One person's contact + service-date row from the group's "DX Info List".
struct DirectoryEntry: Sendable, Hashable {
    let empID: String        // employee number == RosterEntry.workerID
    let phone: String        // formatted, may be empty when not published
    let email: String
    let dispatchStart: String // "M/d/yyyy" — dispatch occupational start
    let companyStart: String  // "M/d/yyyy" — company start
}

/// Read-only directory of dispatcher contact info + PAFCA roles / committees (source: "DX Info List").
/// Contact rows are EMBEDDED (pipe-delimited) and parsed lazily; roles/committees are keyed by employee
/// number so they join directly to roster people (and to [[seniority-store]]).
///
/// NOTE: unofficial reference data — for display/filtering only.
enum DispatcherDirectory {

    // MARK: Contact lookup
    static let byEmpID: [String: DirectoryEntry] = {
        var out: [String: DirectoryEntry] = [:]
        for line in rawContacts.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count == 5 else { continue }
            let id = f[0].trimmingCharacters(in: .whitespaces)
            out[id] = DirectoryEntry(empID: id,
                                     phone: f[1].trimmingCharacters(in: .whitespaces),
                                     email: f[2].trimmingCharacters(in: .whitespaces),
                                     dispatchStart: f[3].trimmingCharacters(in: .whitespaces),
                                     companyStart: f[4].trimmingCharacters(in: .whitespaces))
        }
        return out
    }()
    /// Emp# equivalences: the seniority list and the directory disagree on a few people's employee number
    /// (same person, two IDs). Canonicalize so any lookup resolves regardless of which ID the roster carries.
    static let empAliases: [String: String] = [
        "597172": "773584",   // Susan Cooper — seniority list emp# vs directory/real emp#
    ]
    static func canon(_ id: String) -> String { empAliases[id] ?? id }

    /// Retired / no-longer-active dispatchers who still linger in the master schedule but aren't on the
    /// current PAFCA seniority list or DX Info directory. Filtered out of the roster everywhere (schedule,
    /// matching, Dispatcher list). NOTE: Susan Cooper (597172) is intentionally NOT here — she's active.
    static let retiredEmpIDs: Set<String> = [
        "507286",  // Archer III, Joe
        "426902",  // Demarco, David
        "737875",  // Gleason, Destiny
        "341334",  // Gutt, Kevin
        "539683",  // Lenigan, Gary
        "663483",  // Lepore, Jenn
        "789230",  // Morgan, Kat
        "449943",  // Newman, Kim
        "869723",  // Pena, Caitlyn
        "978033",  // Schwab, Jen
        "621601",  // Stokes, Megan
        "978967",  // Taylor, Meagan
        "553780",  // Turbish, Mark
    ]
    static func isRetired(_ id: String) -> Bool { retiredEmpIDs.contains(id) }

    static func entry(forWorkerID id: String) -> DirectoryEntry? { byEmpID[canon(id)] }

    // MARK: Seniority (rank) — corrected PAFCA-AAL list (15 Jul 2026)
    static let rankByEmpID: [String: Int] = {
        // ORDER-BASED: one empID per line, in seniority order → rank = line position. Inserting a person is
        // just adding their line at the right spot; no renumbering needed.
        var out: [String: Int] = [:]
        var rank = 0
        for line in rawSeniority.split(separator: "\n") {
            let id = line.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            rank += 1
            out[id] = rank
        }
        return out
    }()
    /// Seniority number (1 = most senior), or nil if not on the list.
    static func rank(forWorkerID id: String) -> Int? { rankByEmpID[canon(id)] }
    /// Order people by seniority (most senior first); the unlisted sink to the bottom, by name.
    static func sortedBySeniority(_ people: [(id: String, name: String)]) -> [(id: String, name: String)] {
        people.sorted { a, b in
            switch (rank(forWorkerID: a.id), rank(forWorkerID: b.id)) {
            case let (ra?, rb?): return ra < rb
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return a.name < b.name
            }
        }
    }

    // MARK: PAFCA board (empID → title) + top-of-list order
    static let boardRole: [String: String] = [
        "615888": "President",          // Hart, Alex
        "643917": "Vice President",     // Smith, Randy
        "482209": "Recording Secretary",// Reeves, Matt
        "571939": "Treasurer",          // Forsythe, Brian
        "615583": "Member at Large",    // Dawson, Aaron
    ]
    /// Display order for pinning the board to the top of the list.
    static let boardOrder: [String] = ["615888", "643917", "482209", "571939", "615583"]
    static func boardRank(forWorkerID id: String) -> Int? { boardOrder.firstIndex(of: id) }

    // MARK: Shop stewards
    static let stewards: Set<String> = [
        "773855", "399233", "674677", "572129", "399988", "750539", "109405", "488830",
        "272110", "526153", "472338", "419648", "751195", "676958", "777121", "762455",
        "215405", "764002", "535579", "597105", "108893", "774543", "674352", "674310",
    ]
    static func isSteward(_ id: String) -> Bool { stewards.contains(id) }

    // MARK: Committees (display name → member empIDs). People can be on several.
    static let committees: [String: [String]] = [
        "Election Committee": ["100971", "109405", "526153"],
        "Professional Standards": ["615572", "663639", "753687", "615564", "687232", "741918"],
        "Dispatch Flight Safety-ASAP Committee": ["438253", "570678", "482209", "581942"],
        "Workload Committee": ["35656", "108893", "710144"],
        "Schedule/Bid Committee": ["155834", "100971"],
        "SMS Committee": ["697743", "581942"],
        "Turbulence Task Force": ["570678", "438253", "158728"],
        "PAFCA Web Administrator": ["507947"],
        "ADF": ["597187", "676958"],
        "Jump-Seat Committee": ["587648", "567845", "488830", "210122", "215405"],
        "Accident Investigative Go Team": ["369405", "498249", "438253", "482209", "36685", "25285", "588912"],
        "Military Committee": ["237682", "169710", "445983", "597105"],
        "Leave Committee": ["743887", "660543", "878411"],
        "Dispatch Technology Group (DTG)": ["773580", "793852"],
        "IFALDA": ["613164", "793852"],
        "Dispatch Trade Committee": ["719593", "763999", "603379", "620340", "523734", "643146",
                                      "758745", "292216", "788520", "843858", "660615"],
    ]
    /// empID → committee display names (built once from `committees`).
    static let committeesByEmpID: [String: [String]] = {
        var out: [String: [String]] = [:]
        for (name, ids) in committees { for id in ids { out[id, default: []].append(name) } }
        for k in out.keys { out[k]?.sort() }
        return out
    }()
    static func committees(forWorkerID id: String) -> [String] { committeesByEmpID[canon(id)] ?? [] }

    /// The person's headline position: board title, else "Shop Steward", else nil.
    static func role(forWorkerID id: String) -> String? {
        let c = canon(id)
        return boardRole[c] ?? (stewards.contains(c) ? "Shop Steward" : nil)
    }

    /// All committee filter categories (committees + the two role groups), sorted for the filter menu.
    // PAFCA Board + Shop Steward pinned to the top; committees alphabetical after.
    static let filterCategories: [String] = ["PAFCA Board", "Shop Steward"] + committees.keys.sorted()
    /// Does this worker belong to a filter category (committee name, "PAFCA Board", or "Shop Steward")?
    static func inCategory(_ id: String, _ category: String) -> Bool {
        switch category {
        case "PAFCA Board":  return boardRole[id] != nil
        case "Shop Steward": return stewards.contains(id)
        default:             return committees[category]?.contains(id) ?? false
        }
    }

    // MARK: Qual letter → full name (from the DX Info List legend)
    static let qualNames: [String: String] = [
        "A": "ATC Coordinator", "D": "Domestic", "E": "Europe", "I": "IROPS",
        "J": "OJT Support", "L": "Latin", "O": "Ops Coordinator", "P": "Pacific",
        "R": "Regional Coordinator", "S": "Chief", "Z": "Flight Keys SME",
    ]
    static func qualName(_ letter: String) -> String { qualNames[letter] ?? letter }

    // MARK: Dispatch-start color grouping
    /// Distinct dispatch-start dates → chronological index (0 = earliest). Everyone hired on the same day
    /// shares an index, so the Dispatcher list can give a whole class the same avatar color.
    static let dispatchStartGroupByDate: [String: Int] = {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian); fmt.dateFormat = "M/d/yyyy"
        let dates = Set(byEmpID.values.map { $0.dispatchStart }).filter { !$0.isEmpty }
        let sorted = dates.sorted { (fmt.date(from: $0) ?? .distantPast) < (fmt.date(from: $1) ?? .distantPast) }
        var out: [String: Int] = [:]
        for (i, d) in sorted.enumerated() { out[d] = i }
        return out
    }()
    /// The dispatch-start color group for a worker (nil if no dispatch-start on file).
    static func dispatchStartGroup(forWorkerID id: String) -> Int? {
        guard let d = byEmpID[canon(id)]?.dispatchStart, !d.isEmpty else { return nil }
        return dispatchStartGroupByDate[d]
    }
    /// A real desk-qual code is a single uppercase letter (A, D, E, …). Filters out roster junk tokens
    /// like "f", "-f", "MAX", "maxpay", "no", "qualifications-qualifications" that aren't quals.
    static func isQualCode(_ q: String) -> Bool {
        q.count == 1 && (q.first.map { $0.isUppercase && $0.isLetter } ?? false)
    }

    // MARK: - Embedded seniority — one empID per line, in seniority order (rank = line position).
    // Base = corrected PAFCA-AAL list (15 Jul 2026); + Ellis (after Mulhollen) & Hatcher (after Meek);
    // Cooper = 773584. To insert someone, add their empID line at the right spot — no renumbering.
    private static let rawSeniority = """
24090
38608
100971
472338
363413
159542
543398
25285
35656
450409
520642
352146
110791
548908
110871
36685
16775
4324
485850
526600
13922
16807
8820
141323
438253
141523
174231
542794
122528
310774
310776
310752
311143
9118
342028
174846
165098
84970
302094
132518
173743
179104
162630
341653
336536
360395
155834
171512
302850
412081
481755
424879
190151
535579
572129
570678
192406
199928
412095
493694
560447
447395
526789
356306
522899
432834
475333
507292
389587
399233
327939
445983
169710
322855
581943
581938
581941
581942
351021
386425
484747
567590
514350
624218
624212
624210
624220
624221
624224
624223
624225
624228
624229
624227
624226
358056
624230
624232
158728
460670
480225
518058
549422
624234
624233
624235
624240
624242
624244
192537
395409
413833
192873
397459
419648
100502
316562
470955
467846
390893
538601
507947
581332
597098
620540
620539
368033
627363
378860
399988
486300
369405
397548
151524
526153
521562
549267
170198
395870
450786
548884
513975
615572
615564
615583
311144
650259
663639
597168
643917
615924
616225
616227
616226
567845
172912
330270
367728
406904
480231
597105
597147
597149
674310
656914
615888
135067
440787
627148
488830
692952
615922
617706
617708
660543
660581
660465
660460
571939
561289
505203
112388
109405
394978
560296
482209
674350
109499
520741
493693
498249
608445
613164
621396
643162
643146
655245
659839
655239
574732
460490
543470
439454
783187
773580
773584
773575
773581
773576
773578
773562
773577
773582
674352
108893
597141
763998
764002
628679
763999
605014
764004
764003
66575
147871
597095
567560
677000
754002
757781
200591
750506
757755
674677
685790
608933
753687
201127
597123
597144
643919
843857
587648
588912
619476
591757
750512
750539
201135
481134
485498
550602
777121
761966
587940
615863
595526
595447
597187
593207
460714
698991
420626
603379
620340
350459
758745
652774
753066
764550
700449
701039
700246
536159
774543
758669
758876
200540
706386
755564
744292
742530
743887
589417
742847
597584
743885
773855
687232
762006
751195
843858
843859
687140
764569
856544
866300
591594
589945
690133
698167
203615
816314
655248
740495
801463
223177
700179
225873
716031
866448
301249
724160
687134
740467
224236
687253
223168
223466
753581
222768
581333
773656
147069
676958
754910
508252
863690
547239
596048
718332
733845
802480
233064
234866
232707
233065
589986
758732
233482
233165
864908
762455
195482
758744
782712
205576
719597
627519
59683
719592
730277
719595
773843
215405
719586
719866
53595
211318
719593
719591
205491
719587
719590
598216
747308
212069
740826
816419
248939
20897
417655
444974
467173
201031
580983
477972
733469
208290
272110
802654
741590
741552
741548
741589
741551
700597
741547
741588
215408
228826
741530
745185
761523
741932
741918
224076
242851
213469
603508
628883
761872
203669
773946
758416
729213
202494
208285
793514
793852
793854
760200
742129
792351
73743
793573
793853
241218
782677
523734
229874
211316
794897
743321
740599
796928
431671
645827
686347
631683
697743
677502
732409
228827
207784
757632
263547
266259
224091
736098
260326
717409
710144
260357
706908
759881
260329
791350
260332
263550
353297
717407
286233
296955
260324
181601
750560
762136
291458
291447
736108
296959
291408
640758
291450
736105
377981
275960
806445
291443
737172
223976
735129
292216
713304
293012
291451
301059
291409
291444
224947
210122
230309
788520
262326
806674
237682
240532
788526
273907
211008
706909
427205
660615
777480
844695
595335
707961
258103
705172
878411
878410
878409
295657
878406
713265
878407
206823
857470
246878
878583
206770
847006
945293
262324
886914
206772
211005
223170
945291
758557
877720
31861
719598
238322
295673
893594
885427
878580
885430
297351
713423
970611
970612
803044
247648
746508
794819
372195
811567
231296
893593
928384
878578
231240
231310
231299
791347
211006
877988
609538
759840
710841
260458
260451
240167
260455
865734
"""

    // MARK: - Embedded contacts (empID|phone|email|dispatchStart|companyStart)
    private static let rawContacts = """
560447|(724) 312-3391|donna.abbott@aa.com|4/12/1999|7/5/1979
297351|(772) 882-0783|sami.abdalla@aa.com|7/7/2025|7/7/2025
211005|(901) 646-8124|ahmad.abdelrahim@aa.com|2/10/2025|2/10/2025
241218|(267) 733-7157|starlin.acevedo@psaairlines.com|4/18/2022|4/18/2022
745185|(630) 485-1406|alexander.adams1@aa.com|2/7/2022|2/7/2022
597149|(682) 438-0002|franco.adams@aa.com|10/14/2013|4/5/2004
273907|(520) 339-9939|luciano.adragna@aa.com|9/18/2023|9/18/2023
165098|(480) 403-1241|herbert.aguirre@aa.com|2/10/1992|11/11/1989
700179|(571) 296-8109|tashi.alden@aa.com|9/17/2019|9/17/2019
444974|(817) 657-4274|mir.alikhan@aa.com|2/7/2022|4/22/1996
369405|(937) 474-8548|scott.a.allen@aa.com|7/10/2012|7/10/2012
613164|(423) 502-5921|joshua.anderson@aa.com|12/8/2014|10/5/2012
233165|(208) 716-2467|richard.anderson@aa.com|10/22/2019|10/22/2019
746508|(813) 786-1989|caroline.andrews@aa.com|8/18/2025|8/18/2025
773581|(507) 829-8632|chad.andries@aa.com|1/6/2015|1/6/2015
237682|(817) 807-6915|chris.arde@aa.com|9/18/2023|9/18/2023
13922|(817) 845-7015|joe.arena@aa.com|5/9/1988|11/6/1985
224236|(949) 266-4981|cheukman.au1@aa.com|9/17/2019|9/17/2019
147871|(817) 706-8283|dean.aude@aa.com|4/16/2016|3/26/1987
724160|(740) 803-0553|rachel.aungst@aa.com|9/17/2019|9/17/2019
773577|(704) 960-0550|auterson.laura@gmail.com|1/6/2015|1/6/2015
224091|(678) 326-3783|averyj2@gmail.com|9/6/2022|9/6/2022
755564|(970) 301-2159|chanae.anderson1@gmail.com|9/18/2018|12/1/2014
485498|(480) 309-2560|melissa.azpeitia@aa.com|9/12/2017|5/12/1997
719593|(701) 330-4021|bachman.cody1@gmail.com|12/6/2021|12/6/2021
522899|(412) 726-6788|juanita.bagley@aa.com|4/12/1999|5/6/1985
719586|(832) 372-0888|blake.bagot@aa.com|12/6/2021|12/6/2021
608933|(817) 538-7248|matthew.baier@aa.com|7/17/2017|10/31/2011
878409|(678) 378-6051|glennbailey9250@gmail.com|11/6/2023|11/6/2023
597187|(479) 586-2973|mitchell.baird@aa.com|9/13/2017|9/13/2017
174231|(817) 791-1194|sarah.baker@aa.com|7/17/1989|7/17/1989
718332|(386) 383-5228|joshua.ballard@aa.com|10/22/2019|3/27/2018
742530|(801) 540-7163|matthew.barber@aa.com|9/18/2018|9/18/2018
616226|(901) 734-2676|camelia.barkley@aa.com|10/22/2012|10/22/2012
110871|(817) 706-4542|mark.barry@aa.com|3/30/1987|3/30/1987
591757|(303) 547-7030|alexander.barthule@aa.com|7/18/2017|7/18/2017
390893|(304) 224-9528|mark.bartlett@aa.com|3/31/2008|4/24/2000
203669|(412) 716-2559|marco.bartoletta@aa.com|4/18/2022|10/12/2015
624226|(314) 494-8973|leslie.beard@aa.com|7/23/2000|2/28/2005
232707|(682) 718-1888|christopher.bechtel@aa.com|10/22/2019|10/22/2019
750560|(480) 220-2347|keriellen.beck@gmail.com|10/3/2022|8/16/2014
367728|(214) 734-3281|robbecker10@gmail.com|10/14/2013|3/29/1993
885427|(214) 500-1337|murphy.beckham@aa.com|7/7/2025|7/7/2025
224947|(512) 963-7121|collin.bedford@aa.com|10/3/2022|10/3/2022
857470|(214) 592-2857|jackbednarzwx@gmail.com|2/10/2025|6/23/2023
794819|(619) 964-6503|teiva.berger@aa.com|8/18/2025|8/18/2025
395409|(412) 522-8504|eric.berkebile@aa.com|7/16/2001|7/16/2001
763999|(940) 224-1322|tabatha.edwards@aa.com|6/15/2015|6/15/2015
655248|(406) 661-7708|marla.bickler@aa.com|9/17/2019|12/11/2017
844695|(254) 744-8817|caleb.bilberry@aa.com|11/6/2023|9/6/2016
485850|(412) 865-9067|donald.billings@aa.com|1/11/1988|12/18/1985
624242|(214) 280-1384|jennifer.birkner@aa.com|12/26/2000|1/7/2009
717407|(469) 744-8875|breeblackcfi@gmail.com|9/6/2022|9/6/2022
233482|(901) 691-2198|deangelo.blair@aa.com|10/22/2019|10/22/2019
234866|(801) 598-0112|msrachelblair@gmail.com|10/22/2019|10/22/2019
151524|(937) 554-0028|brian.blatz2@aa.com|7/10/2012|7/10/2012
460670|(817) 991-5794|bryan.blount@aa.com|8/14/2000|6/11/1997
567560|(817) 917-4719|deanna.blue@aa.com|4/16/2016|3/11/2000
208290|(817) 896-4848|william.blume@aa.com|2/7/2022|1/28/2019
201127|(724) 513-4473|alex.bodrie@aa.com|7/17/2017|7/6/2015
761872|(317) 403-5104|ashleigh.broyles@aa.com|4/18/2022|6/8/2015
729213|(724) 513-5893|maxwell.bodrie@aa.com|4/18/2022|5/7/2018
263550|(724) 561-8723|sarah.boles@aa.com|9/6/2022|9/6/2022
603379|(682) 315-2000|liliana.boor@aa.com|12/4/2017|11/1/2011
231296|(954) 540-2718|brett.bories@aa.com|12/2/2025|12/2/2025
878578|(409) 960-1209|jason.boudreaux@aa.com|12/2/2025|12/2/2025
231240|(832) 287-8199|samuel.boulet@aa.com|12/2/2025|12/2/2025
757755|(817) 723-0203|daniel.bova@aa.com|7/17/2017|2/9/2015
743885|(817) 832-2994|connor.bowles@aa.com|9/18/2018|9/18/2018
110791|(817) 929-3987|denny.bowser@aa.com|2/18/1987|2/18/1987
484747|(724) 683-2855|ronald.boxen@aa.com|1/3/2000|9/14/1988
856544|(281) 755-1577|kevin.boydston@aa.com|2/26/2019|2/26/2019
893593|(409) 383-4377|tiffany.boyett@aa.com|12/2/2025|12/2/2025
843857|(817) 658-9452|joshua.boynton@aa.com|7/18/2017|6/6/2016
757632|(214) 500-9787|mark.bradley@aa.com|9/6/2022|10/18/2021
213469|(901) 651-7185|mikle.brady@aa.com|4/18/2022|3/11/2019
620539|(817) 966-2532|jon.branco@aa.com|2/11/2011|1/7/2010
291444|(832) 489-5941|christopher.breuer@aa.com|10/3/2022|10/3/2022
310776|(817) 797-9251|terry.brodin@aa.com|1/7/1991|1/7/1991
302094|(817) 846-8048|rick.brooks@aa.com|4/13/1992|4/8/1991
698167|(214) 893-9684|heather.buchanan@aa.com|9/17/2019|4/27/2015
493694|(972) 352-1912|jeff.burrows@aa.com|1/30/1999|7/28/1997
233064|(281) 381-5485|gregory.burton@aa.com|10/22/2019|10/22/2019
310752|(817) 875-5785|craig.bushey@aa.com|1/7/1991|1/7/1991
589417|(330) 524-8712|kyle.camp@aa.com|9/18/2018|9/18/2018
424879|(724) 480-7224|donald.j.campbell@aa.com|7/6/1998|1/5/1980
260326|(817) 691-7027|michael.canatella1@aa.com|9/6/2022|9/6/2022
538601|(703) 581-2625|stephen.cannon@aa.com|3/31/2008|3/31/2008
293012|(918) 408-9769|joshua.cantrell@aa.com|10/3/2022|10/3/2022
677000|(972) 207-1926|tim.cardin@aa.com|4/16/2016|3/7/2005
291408|(309) 532-4863|michael.carlson1@aa.com|10/3/2022|10/3/2022
719587|(727) 459-7834|mitchell.carreiro@aa.com|12/6/2021|12/6/2021
225873|(469) 262-9670|thalia.carrenobermudez@aa.com|9/17/2019|9/17/2019
440787|(817) 919-7455|sandra.l.carter@aa.com|12/2/2013|2/5/1996
773580|(312) 907-1093|juan.casanova.fernandez@aa.com|1/6/2015|1/6/2015
211006|(817) 791-3020|jack.case@aa.com|12/2/2025|12/2/2025
493693|(817) 937-7813|michael.case@aa.com|12/8/2014|7/28/1997
20897|(817) 875-2830|lajeune.chassagne@aa.com|2/7/2022|8/2/1986
758557|(469) 586-9455|hanna.cho@aa.com|7/7/2025|2/16/2015
866300|(469) 222-1326|alex.j.christian@gmail.com|2/26/2019|2/26/2019
169710|(412) 652-7127|jeff.christiana@aa.com|6/1/1999|6/1/1999
794897|(562) 351-6698|ricardo.cisneros1@aa.com|4/18/2022|4/18/2022
677502|(260) 498-7591|valerie.cline@aa.com|9/6/2022|3/19/2018
758669|(972) 795-5815|dustin.cluff@aa.com|9/17/2018|3/30/2015
741547|(435) 216-8563|emil.cluff@aa.com|2/7/2022|2/7/2022
480231|(817) 726-9164|mark.coates@aa.com|10/14/2013|11/17/1997
619476|(615) 828-1462|alexander.coats@aa.com|7/18/2017|7/18/2017
928384|(678) 876-9218|erica.coats@aa.com|12/2/2025|12/2/2025
570678|(412) 720-0416|michael.p.collier@aa.com|9/8/1998|9/8/1998
793854|(323) 445-9733|michael.r.collins@aa.com|4/18/2022|4/18/2022
363413|(724) 601-9201|terry.collins@aa.com|1/1/1983|5/9/1978
258103|(682) 582-3718|mike.condon@aa.com|11/6/2023|8/7/2021
674350|(817) 715-8104|natasha.cook1@aa.com|2/24/2014|2/24/2014
773584|(936) 355-0734|susan.l.cooper@aa.com|1/6/2015|1/6/2015
597584|(817) 705-6061|brennan.copeland90@gmail.com|9/18/2018|9/18/2018
624230|(817) 705-6429|michael.copeland@aa.com|8/1/2000|7/6/1998
659839|(786) 355-6723|manuel.correa@aa.com|12/8/2014|10/14/2013
377981|(214) 924-4838|cary.countryman@aa.com|10/3/2022|10/3/2022
543398|(480) 225-4754|brenda.cozzens@gmail.com|1/2/1985|7/16/1983
782677|(214) 836-7522|eric.creager@aa.com|4/18/2022|4/18/2022
397548|(214) 701-9244|kyle.crespin@aa.com|7/10/2012|7/10/2012
439454|(724) 601-7703|joshua.crook@aa.com|1/6/2015|2/27/2013
356306|(724) 601-7701|tj.crook@aa.com|4/12/1999|4/26/1985
567845|(817) 320-1544|sean.crosby@aa.com|10/14/2013|11/8/2004
773855|(512) 934-3605|stephen.crossman@aa.com|9/18/2018|9/18/2018
460490|(704) 517-9495|mike.crump@aa.com|1/6/2015|5/27/2008
399233|(682) 888-4733|nigel.cumberbatch@aa.com|6/1/1999|6/1/1999
802654|(972) 333-8364|david.cump@aa.com|2/7/2022|2/7/2022
878411|(352) 809-6013|kenneth.cunningham1@aa.com|11/6/2023|11/6/2023
174846|(682) 429-4598|scott.cunningham@aa.com|11/11/1991|11/26/1989
542794|(412) 855-4668|robert.cupelli@aa.com|10/9/1989|9/14/1981
291443|(720) 280-6873|briancdanahey@gmail.com|10/3/2022|10/3/2022
615572|(682) 465-5377|kevin.b.daniels@aa.com|9/10/2012|9/10/2012
201135|(814) 442-5186|brad@edgefieldproperties.com|9/12/2017|7/21/2015
764003|(208) 290-4181|rtdavidson1989@gmail.com|6/15/2015|6/15/2015
615583|(469) 714-7026|aaron.dawson04@gmail.com|9/10/2012|9/10/2012
893594|(803) 201-8070|brittany.dawson@aa.com|7/7/2025|7/7/2025
477972|(214) 251-7732|fernando.de.la.fuente@aa.com|2/7/2022|1/31/2018
710841|(435) 862-0640|andrew.delossantos@aa.com|2/2/2026|11/1/2021
792351|(435) 319-5673|brent.dean@aa.com|4/18/2022|4/18/2022
740826|(816) 507-8647|sarah.degeare@aa.com|12/6/2021|12/6/2021
759881|(616) 335-1844|michael.dehaan@aa.com|9/6/2022|9/6/2022
865734|(831) 402-9754|julia.delpozzo@aa.com|2/2/2026|2/2/2026
660581|(832) 754-9479|isaias.delgado@aa.com|12/2/2013|12/2/2013
624229|(214) 577-4444|thomas.devange@aa.com|7/23/2000|6/1/1998
231310|(817) 657-6127|steven.dietz@aa.com|12/2/2025|12/2/2025
263547|(618) 600-7949|lilly.p.dimitrova@gmail.com|9/6/2022|9/6/2022
447395|(412) 716-5370|anthony.dinofrio@aa.com|4/12/1999|7/6/1983
713265|(731) 446-6774|andrew.dobbins@aa.com|11/6/2023|11/6/2023
66575|(817) 296-8376|kathy.dolan@aa.com|4/16/2016|1/19/1979
783187|(724) 462-8060|colin.donley@aa.com|1/6/2015|8/25/2014
173743|(817) 689-6141|michael.doran@aa.com|4/8/1996|9/18/1989
773582|(952) 412-5421|sean.dougherty@aa.com|1/6/2015|1/6/2015
389587|(412) 445-8199|david.doughty@aa.com|4/12/1999|4/20/1998
777480|(817) 692-0737|xinxin.callison@aa.com|11/6/2023|6/4/2015
212069|(817) 773-2056|billy.draz@aa.com|12/6/2021|12/6/2021
735129|(615) 364-9285|gregory.dunlop@aa.com|10/3/2022|10/3/2022
754002|(682) 315-7542|charles.durham.iii@aa.com|4/16/2016|11/1/2014
394978|(859) 512-0560|christopher.dutle@aa.com|2/24/2014|2/24/2014
206823|(817) 936-8858|mary.louviere@aa.com|11/6/2023|11/6/2023
275960|(970) 343-2355|dmitry.eddar@aa.com|10/3/2022|10/3/2022
498249|(608) 738-3077|andy.egloff@aa.com|12/8/2014|10/11/1997
628883|(817) 781-5340|lyndsi.ekis@aa.com|4/18/2022|2/8/2013
291447|(985) 860-7121|ellid4@gmail.com|10/3/2022|10/3/2022
223168|(615) 521-9062|ryan.engel1@aa.com|9/17/2019|9/17/2019
608445|(847) 815-4890|brian.engelking@aa.com|12/8/2014|10/10/2011
581938|(817) 964-2159|wayne.erickson@aa.com|8/28/1999|3/31/1997
595526|(505) 702-3290|daniel.escobedo@aa.com|9/13/2017|9/13/2017
687134||juan.estrada@aa.com|9/17/2019|9/17/2019
674677|(817) 851-9561|ricardo.eva@aa.com|7/17/2017|8/1/2005
791350|(330) 883-7450|justin.evans@aa.com|9/6/2022|9/6/2022
877988|(303) 356-5155|nicholas.eylander@aa.com|12/2/2025|12/2/2025
246878|(817) 701-5136|michael.fahmer@aa.com|2/10/2025|2/10/2020
719590|(901) 834-6572|evan.fantom@aa.com|12/6/2021|12/6/2021
507292|(440) 781-6052|david.fatica@aa.com|4/12/1999|12/1/1986
296959|(702) 807-1786|john.ferraro@aa.com|10/3/2022|10/3/2022
620340|(214) 498-7300|mrscourtneyfierro@gmail.com|12/4/2017|11/5/2012
706909|(214) 676-7995|james.fifield@aa.com|9/18/2023|9/18/2023
223177|(225) 636-7579|brian.fike@aa.com|9/17/2019|9/17/2019
773576|(920) 205-6520|michelle.fischer@aa.com|1/6/2015|1/6/2015
260458|(317) 829-4700|jason.flanagan@aa.com|2/2/2026|2/2/2026
548884|(817) 709-5273|john.fletcher@aa.com|9/10/2012|7/26/1999
609538|(703) 462-3653|ruth.ford@aa.com|2/2/2026|12/21/2001
171512|(817) 683-8300|cherri.forgash@aa.com|2/23/1998|1/10/1990
571939|(304) 914-1988|brian.forsythe@aa.com|2/24/2014|8/8/2011
945291|(248) 756-7297|jfrank1868@gmail.com|2/10/2025|2/10/2025
301249|(631) 745-8290|barbara.frey@aa.com|9/17/2019|9/17/2019
706908|(718) 496-2262|poman.fung@aa.com|9/6/2022|9/6/2022
420626|(703) 431-9143|michael.furline@aa.com|12/4/2017|8/10/2009
587940|(682) 667-0526|brett.furlong@aa.com|9/13/2017|1/31/1994
736105|(860) 801-2762|spenser.galloway@aa.com|10/3/2022|10/3/2022
782712|(931) 993-3478|lindsey.galyen@aa.com|12/6/2021|10/28/2019
350459|(412) 977-0313|neil.gamrod@aa.com|12/4/2017|11/25/2013
737172|(615) 957-4841|andrew.garrett1@aa.com|10/3/2022|10/3/2022
741548|(210) 978-3698|michael.gauss@aa.com|2/7/2022|2/7/2022
200591|(901) 387-8811|james.gazlay@aa.com|4/16/2016|6/20/2015
581332|(817) 798-6607|stephanie.geinert@aa.com|2/11/2011|10/11/1996
438253|(724) 312-8602|robert.giangiulio@aa.com|3/13/1989|10/16/1983
378860|(817) 691-2547|kermit.gibson@aa.com|2/21/2011|10/19/1993
352146|(412) 722-8909|randall.gilbert@aa.com|1/1/1987|7/6/1983
624220|(817) 938-2762|kevin.gilkes@aa.com|5/21/2000|9/22/1997
53595|(817) 219-6858|christopher.gillman@aa.com|12/6/2021|12/6/2021
386425|(817) 219-6859|steve.gillman@aa.com|10/11/1999|6/29/1994
645827|(432) 889-0922|timothy.gilmore@aa.com|9/6/2022|9/9/2007
301059|(806) 702-3922|jasmine.godinez@aa.com|10/3/2022|10/3/2022
762136|(210) 387-3815|augustine.gonzales@aa.com|10/3/2022|6/15/2015
223170|(651) 328-0121|sarah.gould@aa.com|2/10/2025|2/10/2025
295657|(214) 853-3134|nickolas.gowans@aa.com|11/6/2023|11/6/2023
615863|(940) 595-1578|richard.b.grainger@aa.com|9/13/2017|9/12/2012
572129|(703) 868-3347|frank.grant@aa.com|7/6/1998|5/17/1989
701039|(603) 799-3717|matthew.d.gray@aa.com|12/5/2017|12/5/2017
372195|(815) 757-1113|mitchell.griesbaum@aa.com|12/2/2025|12/2/2025
260324|(815) 999-1742|matthew.grushkin@aa.com|9/6/2022|9/6/2022
9118|(817) 821-9553|mark.gulledge@aa.com|8/17/1991|2/9/1985
597144|(682) 225-5967|donald.hackett@aa.com|7/18/2017|12/8/2003
719591|(817) 475-2160|ryan.hall@aa.com|12/6/2021|12/6/2021
652774|(254) 718-7057|brian.hamlin@aa.com|12/5/2017|1/25/2011
238322|(817) 944-8539|garrett.hammonds@aa.com|7/7/2025|7/7/2025
266259|(817) 800-1481|michael.haney@aa.com|9/6/2022|9/6/2022
716031|(918) 244-5161|kandace.harris@aa.com|9/17/2019|9/17/2019
427205|(571) 241-6512|nicole.harris@aa.com|11/6/2023|6/27/2011
262324|(214) 681-3431|samharshaw@icloud.com|2/10/2025|2/10/2025
615888|(817) 657-1393|alexander.hart@aa.com|10/14/2013|9/12/2012
190151|(412) 418-9870|fred.hart@aa.com|7/6/1998|8/16/1982
588912|(314) 537-3107|frank.hasper@aa.com|7/18/2017|7/18/2017
719598||justin.hatcher@aa.com|7/7/2025|7/7/2025
353297|(937) 572-6992|benjamin.hause@aa.com|9/6/2022|9/6/2022
713304|(979) 229-9974|jared.hay@aa.com|10/3/2022|10/3/2022
631683|(817) 455-9308|joanna.headley@aa.com|9/6/2022|6/3/2013
685790|(309) 371-8681|ryan.heath@aa.com|7/17/2017|6/16/2010
311144|(817) 637-6878|mike.hentz@aa.com|10/1/2012|7/8/1991
202494|(214) 732-7037|chase.hering@aa.com|4/18/2022|12/3/2018
141523|(214) 563-2717|scott.hering@aa.com|6/12/1989|6/12/1989
759840|(469) 600-8031|beatris.hernandez@aa.com|2/2/2026|5/31/2016
706386|(817) 600-2548|sean.hilty@aa.com|9/17/2018|1/12/2018
135067|(214) 476-7095|bradley.hoffman@aa.com|12/2/2013|6/8/1987
16775|(480) 209-6493|rudolph.hoffman@aa.com|9/14/1987|5/16/1987
760200|(937) 545-3928|keith.holloway1@aa.com|4/18/2022|4/18/2022
295673|(817) 435-3490|alexander.holzworth@aa.com|7/7/2025|7/7/2025
322855|(919) 650-9635|hans.hoover@aa.com|6/24/1999|6/1/1999
741588|(214) 514-8936|john.hope1@aa.com|2/7/2022|2/7/2022
624244|(314) 276-6396|hornje77@gmail.com|2/10/2001|7/11/2009
624235|(817) 657-6297|russel.horn@aa.com|8/31/2000|3/1/2005
802480|(972) 841-4145|greg.j.horner@aa.com|10/22/2019|10/22/2019
615924|(817) 403-3564|jeffrey.e.horner@aa.com|10/22/2012|9/15/2012
327939|(678) 464-0065|steven.horton@aa.com|6/1/1999|6/1/1999
595447|(817) 897-8103|eric.houck@aa.com|9/13/2017|9/13/2017
523734|(551) 697-0873|garnik.hovannesian1@aa.com|4/18/2022|4/18/2022
100971|(412) 977-4000|dawn.howardgutt@aa.com|5/4/1981|5/1/1979
617706|(702) 335-5555|charles.howard@aa.com|12/2/2013|12/5/2012
230309|(949) 266-7126|irene.hsu@aa.com|9/18/2023|9/18/2023
35656|(972) 922-8246|rod.huffman@aa.com|12/16/1985|12/16/1985
627519|(817) 319-9477|brandi.hussey@aa.com|12/6/2021|12/6/2021
886914|(435) 705-6143|timothy.ingraham@aa.com|2/10/2025|2/10/2025
206772|(812) 584-7788|steven.j.jackson@aa.com|2/10/2025|2/10/2025
713423|(214) 554-2550|eric.jang@aa.com|7/7/2025|7/7/2025
640758|(808) 308-8735|kris.jetzer@aa.com|10/3/2022|10/3/2022
736098|(682) 702-2271|nathan.johndro@aa.com|9/6/2022|9/6/2022
687140|(870) 403-6663|bailey.cockerill@aa.com|2/26/2019|2/26/2019
764550|(615) 388-0377|shannon.d.jones@aa.com|12/5/2017|12/5/2017
240167|(302) 853-0099|travis.jones@aa.com|2/2/2026|2/2/2026
663639|(214) 642-7680|caroline.jordan@aa.com|10/22/2012|11/23/2009
395870|(817) 307-9162|david.june@aa.com|9/10/2012|9/25/1995
399988|(724) 630-6825|celina.kane@aa.com|1/9/2012|1/1/2012
141323|(817) 614-6081|stuart.karlson@aa.com|2/6/1989|2/6/1989
412095|(817) 875-7174|rob.karper@aa.com|1/30/1999|5/1/1995
643919|(817) 946-2053|john.karugu@aa.com|7/18/2017|6/5/2011
877720|(806) 729-0044|whitney.katz@aa.com|7/7/2025|7/7/2025
460714|(480) 390-2693|daniel.keck@aa.com|12/4/2017|8/27/2001
801463|(801) 703-3987|sean.kennedy@aa.com|9/17/2019|9/17/2019
624233|(214) 335-4020|matthew.kent@aa.com|8/31/2000|3/1/2005
624227|(214) 264-9572|josephine.keyes@aa.com|7/23/2000|6/1/1998
598216|(512) 954-3077|julie.khuu@aa.com|12/6/2021|12/6/2021
741932|(480) 399-6669|seung.kim@aa.com|2/7/2022|2/7/2022
758744|(940) 208-6201|drew.kimble@aa.com|12/6/2021|3/30/2015
717409|(512) 484-2420|ethan.kinney@aa.com|9/6/2022|9/6/2022
643146|(512) 818-6730|stephanie.kinney@aa.com|12/8/2014|8/12/2013
796928|(214) 641-6126|cameron.klein@aa.com|4/18/2022|4/19/2022
624225|(214) 336-1347|phil.klein@aa.com|7/12/2000|4/17/1998
211008|(214) 558-9313|justin.knight@aa.com|9/18/2023|9/18/2023
753581|(901) 502-0935|latranae.knight@aa.com|9/17/2019|9/17/2019
228827|(218) 206-4448|ktosvold@gmail.com|9/6/2022|6/17/2019
793514|(435) 232-5204|jared.kofoed@aa.com|4/18/2022|4/18/2022
132518|(817) 691-5578|bob.koscheka@aa.com|4/8/1996|3/2/1988
199928|(732) 272-6697|joe.koury@aa.com|1/30/1999|8/1/1990
240532|(817) 205-1892|bradleykramer89@gmail.com|9/18/2023|9/18/2023
397459|(602) 525-3218|manfred.kreiselmeier@aa.com|9/15/2003|9/15/2003
211318|(210) 887-8452|katherine.e.kresek@aa.com|12/6/2021|12/6/2021
643162|(630) 267-5137|tom6165@gmail.com|12/8/2014|8/12/2013
705172|(619) 980-0272|alec.kuzukian@aa.com|11/6/2023|10/18/2021
650259|(682) 315-4810|george.kypreos@aa.com|10/1/2012|1/13/1986
741589|(520) 483-8334|joshua.laboy@aa.com|2/7/2022|2/7/2022
16807|(214) 924-0995|dave.lacki@aa.com|7/2/1988|7/9/1986
8820|(214) 448-5687|rlacoume@gmail.com|10/24/1988|5/6/1985
793852|(850) 543-3619|brian.lafountain@aa.com|4/18/2022|4/18/2022
567590|(724) 312-1169|david.laird@aa.com|1/3/2000|1/3/2000
233065|(973) 204-9813|david.lambert@aa.com|10/22/2019|10/22/2019
758745|(315) 663-4887|amy_langham@yahoo.com|12/4/2017|3/30/2015
316562|(724) 396-5770|jeffrey.larkin@aa.com|9/24/2007|9/24/2007
223976|(936) 337-3550|john.larue@aa.com|10/3/2022|10/3/2022
591594|(945) 358-8322|kara.s.lawrence@aa.com|9/17/2019|7/17/2017
970612|(904) 525-3665|john.layton@aa.com|8/18/2025|8/18/2025
764569|(502) 460-6979|jacob.leachman@aa.com|2/26/2019|2/26/2019
351021|(214) 395-0971|mike.leake@aa.com|10/11/1999|10/4/1992
686347|(863) 537-0892|kristen.lease@aa.com|9/6/2022|8/14/2010
292216|(917) 613-7022|ervin.lee@aa.com|10/3/2022|10/3/2022
773656|(352) 598-7948|ryan.leeward@aa.com|9/20/2019|9/20/2019
593207|(724) 413-4424|scott.lemasters@aa.com|9/13/2017|9/13/2017
170198|(786) 253-7283|david.lemus@aa.com|9/10/2012|5/27/1989
615922|(214) 897-0507|fengqin.li-stump@aa.com|12/2/2013|9/15/2012
505203|(317) 418-2375|ronald.lindsey@aa.com|2/24/2014|2/24/2014
286233|(817) 901-2709|juan.londonocano@aa.com|9/6/2022|9/6/2022
597147|(214) 288-6298|ryan.long@aa.com|10/14/2013|1/19/2004
84970|(817) 283-5667|david.looper@aa.com|4/13/1992|4/15/1984
707961|(818) 419-4415|annasophialowe@gmail.com|11/6/2023|5/4/2018
816419|(702) 336-1134|gary.lowe@aa.com|2/7/2022|5/31/2016
750539|(970) 402-6630|matthew.lowry@aa.com|9/12/2017|7/29/2014
806445|(817) 673-2496|matthew.lum@aa.com|10/3/2022|10/3/2022
526600|(412) 716-6185|joe.maccarone@aa.com|3/7/1988|2/6/1978
507947|(412) 855-8370|michael.marticek@aa.com|3/31/2008|3/31/2008
223466|(219) 229-8084|randall.martin@aa.com|9/17/2019|9/17/2019
109405|(920) 277-0371|richard.p.martin@aa.com|2/24/2014|2/24/2014
215408|(720) 483-2730|jessica.martinez1@aa.com|2/7/2022|2/7/2022
740599|(360) 525-5765|kimberly.rangelmartinez@aa.com|4/18/2022|4/18/2022
655245|(254) 721-2402|jeffrey.martinson@aa.com|12/8/2014|10/14/2013
488830|(254) 718-3719|mark.martinson@aa.com|12/2/2013|4/18/2007
624223|(817) 354-5968|gary.maslankowski@aa.com|7/7/2000|3/30/1998
730277|(256) 683-7074|joel.matey@aa.com|12/6/2021|12/6/2021
741530|(786) 212-4915|a.mathew@aa.com|2/7/2022|2/7/2022
272110|(832) 452-3819|jose.matos@aa.com|2/7/2022|2/2/2021
624240|(713) 502-3705|john.matthewsjr@aa.com|11/30/2000|11/9/2006
595335|(817) 970-4410|kevin.matthews@aa.com|11/6/2023|8/21/2017
597168|(817) 681-1032|silas.mayall@aa.com|10/22/2012|12/13/2010
514350|(412) 716-4008|scott.maynard@aa.com|1/24/2000|1/24/2000
112388|(317) 412-3228|trenton.mcartor@aa.com|2/24/2014|2/24/2014
773946|(304) 650-9592|matthew.mccall@aa.com|4/18/2022|4/10/2017
59683|(801) 845-8289|lonnie.mcclelland@aa.com|12/6/2021|12/6/2021
210122|(502) 415-3363|curtis.mccoy@aa.com|10/3/2022|10/3/2022
788520|(609) 947-3243|gregory.mccutcheon@aa.com|9/18/2023|9/18/2023
628679|(682) 888-7388|dustin.mcdonald@aa.com|6/15/2015|6/15/2015
203615|(832) 249-9222|john.mceuen@aa.com|9/17/2019|10/12/2015
743321|(865) 405-9438|jessica.mcginley@aa.com|4/18/2022|4/18/2022
536159|(224) 659-1821|michael.t.mcgovern@aa.com|9/17/2018|1/27/2015
736108|(337) 255-4741|wesley.mcgowan@aa.com|10/3/2022|10/3/2022
159542|(412) 498-9076|blake.mckee@aa.com|4/16/1984|3/1/1980
310774|(817) 312-7643|jeff.mclaren@aa.com|1/7/1991|1/7/1991
526153|(602) 541-0304|rachael.mcmahon@aa.com|7/10/2012|7/10/2012
445983|(412) 865-7777|joseph.mealie@aa.com|6/1/1999|6/1/1999
624224|(817) 845-1598|michael.mealie@aa.com|7/7/2000|3/30/1998
31861|(580) 977-8992|jaime.meek@aa.com|7/7/2025|7/7/2025
741551|(503) 737-9918|steven.mercer@aa.com|2/7/2022|2/7/2022
260357|(417) 839-6157|daniel.meyer1@aa.com|9/6/2022|9/6/2022
222768|(724) 747-8503|nicholas.miller@aa.com|9/17/2019|9/17/2019
260455||ryan.mills@aa.com|2/2/2026|2/2/2026
109499|(724) 689-8329|james.p.mitchell@aa.com|2/24/2014|2/24/2014
560296|(586) 453-4174|kfelkowski@yahoo.com|2/24/2014|2/24/2014
864908|(315) 520-4788|benjamin.moll@aa.com|10/22/2019|10/22/2019
200540|(603) 957-0233|andrew.j.moore@aa.com|9/17/2018|6/29/2015
750512|(469) 559-2359|julie.hibbs@aa.com|9/12/2017|7/28/2014
843858|(972) 804-8996|robert.moore.jr@aa.com|2/26/2019|2/26/2019
181601|(480) 438-8489|jowell.morgan@aa.com|10/3/2022|4/22/2013
660543|(703) 728-6703|summer.morgan@aa.com|12/2/2013|12/2/2013
224076|(724) 601-3764|alan.moss@psaairlines.com|2/7/2022|2/7/2022
192873|(321) 960-8016|kevin.a.mueller@aa.com|1/21/2003|1/21/2003
291458|(702) 285-9165|richard.mulhollen@aa.com|10/3/2022|10/3/2022
155834|(817) 726-5900|gjmullen66@gmail.com|2/23/1998|12/9/1988
878410|(954) 830-8006|anderson.munozacevedo@aa.com|11/6/2023|11/6/2023
878407|(713) 540-8554|spencer.murdock@aa.com|11/6/2023|11/6/2023
587648|(702) 234-8523|brent.murray@aa.com|7/18/2017|7/18/2017
791347|(940) 765-5963|robert.musacchio@aa.com|12/2/2025|12/2/2025
597123|(214) 529-7031|brian.nack@aa.com|7/18/2017|5/7/2001
843859|(425) 223-8872|julie.nehls@aa.com|2/26/2019|2/26/2019
719595|(314) 449-4536|sajen.nelson@aa.com|12/6/2021|12/6/2021
793853|(281) 639-5326|ewneuendorf@gmail.com|4/18/2022|4/18/2022
719866|(952) 221-9392|wesley.neuman@aa.com|12/6/2021|12/6/2021
741590|(360) 980-9827|annaliza.niblack@aa.com|2/7/2022|2/7/2022
741552|(360) 773-1662|v.niblack@aa.com|2/7/2022|2/7/2022
472338|(412) 719-7827|david.noble@aa.com|11/1/1982|12/16/1978
208285|(970) 388-9530|toby.nordhoff@aa.com|4/18/2022|1/28/2019
700449|(407) 446-7299|stephen.oakley@aa.com|12/5/2017|12/5/2017
589986|(817) 217-3964|juan.ochoa@aa.com|10/22/2019|10/22/2019
758416|(817) 233-8921|wesley.ogana@aa.com|4/18/2022|9/5/2017
192537|(480) 620-9630|todd.olson@aa.com|4/16/2001|4/16/2001
38608|(817) 874-4642|tom.oneill@aa.com|2/9/1980|6/15/1976
431671|(682) 347-9586|robert.ortiz2@aa.com|9/6/2022|8/1/1995
710144|(440) 282-5976|mitchell.ostang@aa.com|9/6/2022|9/6/2022
311143|(817) 726-6205|mitch.ott@aa.com|7/8/1991|7/8/1991
229874|(210) 792-9070|julian.pacheco@aa.com|4/18/2022|4/18/2022
207784|(724) 987-0840|colin.paich@aa.com|9/6/2022|10/8/2019
470955|(724) 312-7131|randy.palmer@aa.com|3/31/2008|4/24/1981
589945|(214) 228-4798|tyson.palmer@aa.com|9/17/2019|7/17/2017
811567|(706) 936-5119|natkamon.panyavuthilert@aa.com|12/2/2025|1/24/2023
260332|(925) 597-1351|raynardron95@gmail.com|9/6/2022|9/6/2022
549422|(940) 312-9266|gary.pascoe@aa.com|8/14/2000|3/21/2001
260451||alan.pastreck@aa.com|2/2/2026|2/2/2026
247648|(405) 541-8798|byron.paul@aa.com|8/18/2025|8/18/2025
543470|(724) 554-8837|alpalpauli@gmail.com|1/6/2015|1/31/2011
878583|(214) 250-8533|adam.pawelczyk@aa.com|2/10/2025|2/10/2025
206770|(214) 681-8269|cash.payne@aa.com|2/10/2025|2/10/2025
624221|(817) 657-2116|scott.pennoyer@aa.com|7/7/2000|3/30/1998
195482|(214) 929-3581|clemente.perez@aa.com|12/6/2021|4/4/1990
417655|(787) 550-0311|eric.perez@aa.com|2/7/2022|4/13/1995
432834|(724) 650-0109|dan.persuit@aa.com|4/12/1999|10/21/1985
761966|(724) 650-4755|derek.persuit@aa.com|9/12/2017|6/1/2015
655239|(214) 629-5016|cameron.pessin@aa.com|12/8/2014|10/14/2013
624232|(972) 696-9703|edward.peters@aa.com|8/1/2000|7/6/1998
762006|(901) 218-8192|emily.phan.mceuen@aa.com|2/25/2019|6/8/2015
773843|(787) 946-6611|simon.philipos@aa.com|12/6/2021|12/6/2021
260329|(414) 243-2312|michael.phillips@aa.com|9/6/2022|9/6/2022
518058|(817) 919-8490|james.pierce@aa.com|8/14/2000|1/5/1999
616227|(801) 556-9611|jon.pierce@aa.com|10/22/2012|10/22/2012
342028|(817) 991-2047|scott.piner@aa.com|9/9/1991|9/9/1991
581943|(817) 442-1216|mike.pisenti@aa.com|8/28/1999|3/8/1993
419648|(602) 705-7301|kelly.poindexter@aa.com|9/15/2003|9/15/2003
262326|(405) 326-6706|jason.ponder@aa.com|9/18/2023|9/18/2023
732409|(682) 208-8382|alexander.portillo@aa.com|9/6/2022|5/7/2018
248939|(682) 553-1046|ana.prakash@aa.com|2/7/2022|2/10/2020
24090|(214) 923-4318|paul.prizzi@aa.com|9/27/1975|1/3/1974
793573|(630) 926-4186|zachary.prkut@aa.com|4/18/2022|4/18/2022
660465|(865) 318-6120|sethprovince@gmail.com|12/2/2013|12/2/2013
574732|(718) 924-3959|riad.puchoon@aa.com|12/8/2014|6/6/2014
580983|(727) 267-6915|jacob.qualtiere@aa.com|2/7/2022|6/19/2017
521562|(682) 365-8122|robert.quattrochi@aa.com|9/10/2012|4/20/1998
687253|(817) 681-9434|casey.raaz@aa.com|9/17/2019|9/17/2019
581333|(817) 933-7747|miranda.michaeli@aa.com|9/17/2019|9/17/2019
162630|(817) 637-3392|jon.ramirez@aa.com|4/8/1996|1/8/1990
467846|(412) 974-9264|redjeep1992@hotmail.com|3/31/2008|5/24/1993
291409|(937) 408-9093|nauman.rauf@aa.com|10/3/2022|10/3/2022
360395|(214) 734-7609|chris.reck@aa.com|4/8/1996|7/6/1992
751195|(903) 267-9805|michael.roy.redd@gmail.com|2/26/2019|6/23/2014
750506|(517) 438-0230|michael.reed@aa.com|7/17/2017|8/11/2014
878580|(716) 302-9110|trey.rees@aa.com|7/7/2025|7/7/2025
482209|(330) 221-5235|matthew.reeves@aa.com|2/24/2014|2/24/2014
597098|(817) 357-5874|alan.reich@aa.com|2/11/2011|7/15/2001
550602|(817) 229-5352|miguel.relayze@aa.com|9/12/2017|12/14/1998
660460|(785) 220-2219|joseph.revell@aa.com|12/2/2013|12/2/2013
100502|(480) 326-7835|alejandro.reyes@aa.com|11/14/2005|11/14/2005
676958|(440) 541-4562|arturo.m.reyes@aa.com|10/22/2019|8/3/2005
475333|(817) 319-7575|john.rhine@aa.com|4/12/1999|9/10/1986
777121|(812) 560-8307|justin.riechers@aa.com|9/12/2017|4/20/2015
863690|(847) 707-4107|kyle.riesner@aa.com|10/22/2019|12/12/2016
302850|(817) 688-4751|julia.robichaux@aa.com|2/23/1998|6/5/1990
788526|(210) 792-8812|christopher.robinson2@aa.com|9/18/2023|9/18/2023
624234|(817) 262-3502|randal.robinson@aa.com|8/31/2000|3/1/2005
692952|(787) 717-4028|wildalis.robles@aa.com|12/2/2013|10/15/2007
336536|(214) 674-5285|gene.rochowski@aa.com|4/8/1996|11/20/1991
733845|(940) 312-8589|nicholas.rochowski@aa.com|10/22/2019|5/21/2018
762455|(615) 944-7973|mrodell10@gmail.com|10/22/2019|10/22/2019
231299|(305) 338-2863|albertorod397@gmail.com|12/2/2025|12/2/2025
603508|(817) 983-9095|daniel.rogers@aa.com|4/18/2022|7/24/2000
520642|(412) 841-6466|terry.h.rogers@aa.com|1/1/1987|6/1/1981
624210|(817) 937-7287|valmar.romero@aa.com|5/14/2000|8/3/1992
513975|(817) 946-3985|romine.jamie@gmail.com|9/10/2012|10/18/1999
36685|(214) 448-5634|lee.roper@aa.com|3/30/1987|12/1/1986
970611|(786) 543-5580|jerv60@gmail.com|8/18/2025|8/18/2025
215405|(859) 240-2594|ashley.ross@aa.com|12/6/2021|12/6/2021
242851|(724) 647-8666|brett.rossi1@aa.com|2/7/2022|2/7/2022
597095|(817) 680-0957|christopher.roush@aa.com|4/16/2016|2/28/2000
616225|(817) 757-0574|daniel.royal@aa.com|10/22/2012|10/22/2012
412081|(682) 429-8087|chris.ruhberg@aa.com|2/23/1998|4/10/1995
481134|(305) 528-6588|alexander.samuel@aa.com|9/12/2017|2/24/1997
806674|(817) 412-0244|joshua.sanchez.martinez@aa.com|9/18/2023|9/18/2023
764002|(972) 251-9261|nicholas.sanchez@aa.com|6/15/2015|6/15/2015
698991|(614) 499-4201|matthew.sanders@aa.com|12/4/2017|2/24/2007
700597|(214) 650-1521|abismael1.santiago@aa.com|2/7/2022|2/7/2022
581942|(817) 781-7936|jrsarge23@yahoo.com|8/28/1999|4/14/1997
228826|(505) 553-4157|timothy.sayamontry@aa.com|2/7/2022|2/7/2022
773575|(919) 285-6585|jjscharle@gmail.com|1/6/2015|1/6/2015
330270|(214) 621-1511|layne.schlemmer@aa.com|10/14/2013|9/16/1991
803044|(757) 201-4113|adrianne.schneider@aa.com|8/18/2025|8/18/2025
816314|(210) 705-2545|cory.schneider@aa.com|9/17/2019|5/31/2016
605014|(412) 865-7457|david.a.schnurer@aa.com|6/15/2015|6/15/2015
624218|(817) 966-3720|schultzduo@gmail.com|3/16/2000|1/2/1997
413833|(480) 326-9338|matthew.schwalm@gmail.com|7/25/2001|7/25/2001
296955|(214) 701-1534|christian.schwoyer@aa.com|9/6/2022|9/6/2022
620540|(214) 697-6331|john.schwoyer@aa.com|2/11/2011|3/25/2002
885430|(214) 701-0063|luke.schwoyer@aa.com|7/7/2025|7/7/2025
624212|(817) 874-3871|brennan.scott@aa.com|4/15/2000|8/14/1995
291450|(702) 782-0587|jerico.sebrio@aa.com|10/3/2022|10/3/2022
627363|(817) 937-1710|victor.semper@aa.com|2/14/2011|6/10/2002
744292|(920) 585-6442|derek.severin@aa.com|9/18/2018|9/18/2018
205491|(512) 568-0259|hannahbread92@yahoo.com|12/6/2021|12/6/2021
719592|(317) 778-9690|mohammedshaad.shaikh@aa.com|12/6/2021|12/6/2021
406904|(817) 845-5897|william.sharp@aa.com|10/14/2013|10/16/1995
201031|(817) 403-3414|michael.sheehan@aa.com|2/7/2022|6/22/2015
742847|(602) 390-2806|zachary.shepherd@aa.com|9/18/2018|9/18/2018
4324|(817) 422-6322|bob.shirley@aa.com|12/7/1987|5/6/1985
535579|(954) 559-3120|art.siebenaler@aa.com|7/6/1998|9/26/1988
740495|(214) 846-3205|michael.silverwood@aa.com|9/17/2019|9/17/2019
719597|(603) 479-5498|rod.silverwood@aa.com|12/6/2021|12/6/2021
480225|(214) 642-6388|brian.simons@aa.com|8/14/2000|6/10/1998
450786|(817) 939-5713|mark.smiley@aa.com|9/10/2012|8/12/1996
747308|(571) 839-4942|daniel.smith3@aa.com|12/6/2021|12/6/2021
358056|(602) 820-1007|kermie3069@aol.com|7/24/2000|7/24/2000
643917|(817) 726-2520|rsmith72385@gmail.com|10/22/2012|6/5/2011
158728|(817) 308-4990|stephen.smith@aa.com|8/14/2000|8/18/1989
763998|(260) 388-1136|gregory.t.smith@aa.com|6/15/2015|6/15/2015
656914|(646) 484-9086|sasha.souhala-ahmed@aa.com|10/14/2013|11/18/2008
773562|(703) 625-8579|ryan.spaulding@aa.com|1/6/2015|1/6/2015
73743|(660) 864-4688|rebecca.speer@aa.com|4/18/2022|4/18/2022
179104|(817) 791-0000|jody.sporisky@aa.com|4/8/1996|1/3/1990
597105|(817) 999-4382|jenny.sprigg@aa.com|10/14/2013|7/16/2000
627148|(817) 845-1895|staaky@hotmail.com|12/2/2013|3/9/2004
172912|(817) 798-1310|joseph.statz@aa.com|10/14/2013|11/26/1990
108893|(480) 577-3383|kelsey.steger@aa.com|6/15/2015|7/22/2013
866448|(330) 469-3148|chelsea.stevens@aa.com|9/17/2019|9/17/2019
764004|(405) 627-4792|ryan.stradone@aa.com|6/15/2015|6/15/2015
733469|(305) 575-9931|ryan.stratton@aa.com|2/7/2022|5/30/2018
617708|(301) 502-8851|matthew.straub@aa.com|12/2/2013|12/5/2012
878406|(615) 796-3219|jillian.sulcer@aa.com|11/6/2023|11/6/2023
742129|(316) 708-3708|todd.sullivan@aa.com|4/18/2022|4/18/2022
753687|(918) 384-9247|john.svadlenka@aa.com|7/17/2017|10/20/2014
761523|(817) 846-3875|lydia.tallon@aa.com|2/7/2022|2/7/2022
741918|(636) 281-6147|hudson.taylor@aa.com|2/7/2022|2/7/2022
526789|(724) 679-1189|eric.thomas@aa.com|4/12/1999|3/26/1985
462440|(412) 498-0655|gregory.thorstensen@aa.com|3/13/1989|6/22/1987
486300|(412) 721-7156|brian.todd@aa.com|7/10/2012|6/15/1987
740467|(850) 974-3611|micah.torres1@aa.com|9/17/2019|9/17/2019
508252|(940) 535-4852|tovar.david@aa.com|10/22/2019|2/22/2016
368033|(817) 209-8896|di.tran@aa.com|2/14/2011|12/12/1993
341653|(817) 874-6421|bill.trott@aa.com|4/8/1996|9/30/1991
700246|(806) 543-2773|blaine.true@aa.com|12/5/2017|12/5/2017
291451|(562) 201-4151|jessica.tsai@aa.com|10/3/2022|10/3/2022
945293|(206) 468-6109|jared.tyrol@aa.com|2/10/2025|2/10/2025
660615|(786) 543-9145|ivet.valdivieso@aa.com|11/6/2023|1/8/2014
624228|(817) 845-9301|claude.vanderpool@aa.com|7/23/2000|6/1/1998
754910|(901) 921-8977|takira.vasser@aa.com|10/22/2019|7/6/2015
467173|(347) 935-0607|steven.vega@aa.com|2/7/2022|7/1/2012
758732|(808) 315-0403|aceadriel.viceo@aa.com|10/22/2019|10/22/2019
774543|(305) 801-8872|jennifer.vivero@aa.com|9/17/2018|2/9/2015
481755|(412) 716-0014|derek.voege@aa.com|6/1/1998|6/1/1998
147069|(469) 708-8468|tim.wade@aa.com|10/22/2019|12/31/1985
597141|(817) 372-3743|peter.waite@aa.com|6/15/2015|6/15/2015
520741|(724) 777-9429|william.walbek@aa.com|12/8/2014|4/21/1983
561289|(682) 218-9672|peter.walker1@aa.com|2/24/2014|2/24/2014
205576|(813) 300-2207|timothy.s.walters1@aa.com|12/6/2021|12/6/2021
581941|(817) 726-3642|john.warren@aa.com|8/28/1999|1/15/1994
753066|(214) 766-4164|joli.watkins@aa.com|12/5/2017|9/8/2014
192406|(817) 675-9108|christina.weinberg@aa.com|1/30/1999|7/9/1990
773578|(224) 715-8153|christoffe.wenger@aa.com|1/6/2015|1/6/2015
847006|(804) 754-6244|nicholas.westfall@psaairlines.com|2/10/2025|2/10/2025
758876|(678) 588-2030|matthew.white@aa.com|9/17/2018|4/27/2015
548908|(724) 622-9214|stephen.whittier@aa.com|3/1/1987|5/20/1983
547239|(509) 671-1775|devon.willenbrock@aa.com|10/22/2019|6/19/2017
674352|(817) 602-1868|lawrence.williamson@aa.com|6/15/2015|2/15/2010
674310|(214) 454-2767|monica.williamson@aa.com|10/14/2013|8/29/2005
122528|(817) 680-7865|therese.wingert@aa.com|12/3/1990|10/31/1987
697743|(817) 706-9385|wise.lauren@gmail.com|9/6/2022|5/25/2015
25285|(972) 365-9950|damon.wood@aa.com|9/3/1985|9/3/1985
615564|(417) 439-6967|gerred.woodard@aa.com|9/10/2012|9/10/2012
690133|(817) 637-0852|heather.woodgate@aa.com|9/17/2019|3/9/1987
549267|(817) 691-1549|jeff.wray@aa.com|9/10/2012|9/7/2000
596048|(763) 807-0913|peter.xiong@aa.com|10/22/2019|8/21/2017
621396|(516) 698-0067|jaclyn.yako@aa.com|12/8/2014|1/7/2013
743887|(214) 463-1304|bethany.zabcik@aa.com|9/18/2018|9/18/2018
687232|(817) 487-9252|eric.zimmerman@aa.com|9/18/2018|9/18/2018
211316|(210) 835-4353|jordan.t.zurenko@aa.com|4/18/2022|4/18/2022
"""
}
