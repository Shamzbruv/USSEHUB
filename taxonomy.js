/*
 * USSE Hub 2026 listing taxonomy.
 *
 * Client sources:
 * - CATEGORIES & SUBS-2026-UsseHub - Listing.docx (revised hierarchy)
 * - ver2 -CATEGORIES & SUBS-2026-UsseHub - Listing.docx (cleaner regrouping)
 * - Test 3b - Categorize -Untitled.html (client-supplied interaction prototype)
 * - Category testing -DOCTYPE html.htm.html (export of the prototype)
 *
 * The live listing table currently stores one primary `category` and one
 * `subcategory`. The secondary, tertiary and optional specific-type path is
 * therefore stored in `subcategory` using a readable ` › ` separator.
 */

const TAXONOMY = {
    "GENERAL": {
        "TRANSPORT - PUBLIC": {
            tertiary: ["MAINTENANCE", "REPAIRS", "CONSTRUCTION", "DELIVERY / PICKUPS", "CATERING"],
            specific: ["LAND", "AIR", "SEA", "GARAGES", "CENTRES", "FOODS", "NON-FOODS"]
        },
        "TRANSPORT - PRIVATE": {
            tertiary: ["RENTALS & LEASES", "CHARTERS", "MAINTENANCE & REPAIRS"],
            specific: ["LAND", "AIR", "SEA", "COURIER", "DELIVERY / PICKUPS", "CATERING (FOODS)", "CATERING (NON-FOODS)"]
        },
        "HEALTH & WELLNESS": {
            tertiary: ["WELLNESS & FITNESS"],
            specific: ["GYMS", "SPAS", "MEDITATION", "MARTIAL ARTS (YOGA / TM)", "TRACK & FIELD"]
        },
        "PERSONAL CARE": {
            tertiary: ["GROOMING", "COSMETICS"],
            specific: ["SALONS", "BARBER SHOPS"]
        },
        "MEDICAL": {
            tertiary: ["CLINICS", "HOSPITALS"],
            notes: ["General medical facilities"]
        },
        "EDUCATIONAL": {
            tertiary: ["PUBLIC & PRIVATE SERVICES"],
            specific: [
                "DAY CARE",
                "KINDERGARTEN / PRE-SCHOOL",
                "PRIMARY",
                "SECONDARY",
                "TRAINING CENTRES",
                "LIBRARY SERVICES",
                "COMMUNITY CENTRES",
                "INFIRMARIES",
                "TERTIARY - COMMUNITY COLLEGES",
                "TERTIARY - UNIVERSITIES"
            ]
        },
        "COMMUNICATIONS": {
            tertiary: ["TELEPHONY", "MEDIA NEWS", "INTERNET", "SATELLITE"],
            specific: ["WEB DEVELOPMENT", "NETWORK CAFES", "INSTALLATIONS", "SERVICING & REPAIRS"]
        },
        "AUDIO / VISUAL": {
            tertiary: ["GRAPHIC DESIGNS", "MUSICAL STUDIOS", "PHOTO STUDIO SERVICES"],
            specific: ["MARKETING / PROMOTIONS"]
        }
    },
    "PROPERTY MANAGEMENT SERVICES": {
        "RESIDENTIAL / COMMERCIAL": {
            tertiary: ["VENUE PLANNING", "EVENTS PLANNING"],
            notes: ["Property administration and events"]
        }
    },
    "FINANCIAL SERVICES": {
        "INSTITUTIONS - LOCAL & INTERNATIONAL": {
            tertiary: ["BANKS", "INSURANCE", "INVESTMENTS", "DIGITAL"],
            notes: ["Financial instruments and banking"]
        }
    },
    "NGO / SERVICE CLUBS": {
        "LOCAL & INTERNATIONAL": {
            tertiary: ["RELIGIOUS CENTRES & BRANCHES", "CIVIC / SERVICE CLUBS"],
            notes: ["Community and global organizations"]
        }
    },
    "REAL ESTATE": {
        "PROPERTY MANAGEMENT - SALES, RENTALS, LEASES, ROOMS & VENUES": {
            tertiary: ["ACCOMMODATIONS", "CONVENTIONAL VENUES", "WAREHOUSES", "LAND LOTS"],
            specific: [
                "RESORT / LEISURE",
                "MEETINGS / CONFERENCES",
                "PARKS",
                "RESIDENTIAL",
                "COMMERCIAL",
                "ENTERTAINMENT",
                "BUSINESS",
                "STADIUMS",
                "ATTRACTIONS",
                "AUDITORIUMS / CENTRES"
            ]
        },
        "RETAIL": {
            tertiary: ["SHOPPING STORE OUTLETS", "SUPPLY CENTRES", "STORAGE FACILITIES"],
            specific: [
                "SUPERMARKETS",
                "FLORISTS",
                "ELECTRONICS",
                "PHARMACEUTICAL",
                "HEALTH FOOD & BEVERAGE SUPPLIES",
                "BOOK STORES / CLUBS",
                "CONVENIENCE / COMMISSARIES",
                "HARDWARE & CONSTRUCTION SUPPLIES",
                "COMMERCIAL EQUIPMENT & DEVICES",
                "MARKETS & STALLS",
                "CRAFT MARKETS"
            ]
        }
    },
    "FOOD & BEVERAGE": {
        "DINING OUTLETS": {
            tertiary: ["BARS", "RESTAURANTS", "TO-GO OUTLETS / DELIS"],
            specific: ["FULL SERVICE", "CAFES", "REST STOPS", "DRIVE-THROUGH"]
        },
        "STORAGE & DISTRIBUTION": {
            tertiary: ["DEPOTS - ALL TYPES", "DISTRIBUTION OUTLETS"],
            specific: ["COLD STORAGE", "DRY STORAGE", "FOOD & BEVERAGE", "HONEY", "MEATS"]
        }
    },
    "FARMING & AGRICULTURE": {
        "AGRICULTURE": {
            tertiary: ["LIVESTOCK & POULTRY", "CROPS & PRODUCE", "HORTICULTURE"],
            specific: ["CATTLE", "POULTRY", "HERBS & SPICES", "VEGETABLES", "FRUITS", "GROUND PROVISIONS", "GENERAL CROPS"]
        },
        "FISHERIES": {
            tertiary: ["FRESHWATER PONDS", "SEA CATCHMENTS"],
            notes: ["Commercial and local fishing"]
        }
    },
    "CONSTRUCTION": {
        "RESIDENTIAL & COMMERCIAL": {
            tertiary: ["TRADES & MASONRY", "CARPENTRY & WELDING", "PAINTING & SURVEYING"],
            specific: ["PROPERTY VALUATION", "BUILDER / CONTRACTOR", "STRUCTURAL MAINTENANCE"]
        }
    },
    "AUTO CARE SERVICES": {
        "CAR CARE CENTRES": {
            tertiary: ["MAINTENANCE & REPAIRS", "CLEANING & DETAILING"],
            specific: ["ENGINE REPAIRS", "TRANSMISSION", "ALIGNMENT", "TYRES", "CAR WASH", "INTERIOR CAR DETAILING"]
        }
    },
    "ENTERTAINMENT": {
        "LIVE & PRE-RECORDED": {
            tertiary: ["HOSTED EVENTS", "VENUES & SHOWS"],
            specific: ["CLUBS", "PARTIES", "CINEMA", "ARENAS", "STAGE SHOWS", "AUDITORIUMS", "PARKS"],
            qualifiers: ["ADULT", "GENERAL", "KIDS", "SEASONAL"]
        }
    }
};

/*
 * Historical data is retained for existing listings only. Hidden legacy
 * primary options allow an old listing to load without blanking its saved
 * category, while new submissions see only the 2026 taxonomy above.
 */
const LEGACY_TAXONOMY = {
    "SERVICES": {
        "GENERAL": ["TRANSPORT (RENTALS, LEASE, CHARTERS)", "MAINTENANCE (PAINTING, CARPENTRY, CARPET CLEANING, CAR CARE CENTRES)", "REPAIRS (AUTO GARAGES, ELECTRONIC, HOMES & OFFICES, MACHINERY)", "CONSTRUCTION (RESIDENTIAL, COMMERCIAL, FIXTURES)", "DELIVERY/PICKUPS (FOODS, NON-FOODS)", "CATERING (LOW BUDGET/SMALL EVENTS, GENERAL-MODERATE/LARGE EVENTS)"],
        "HEALTH & WELLNESS": ["MEDICAL (CLINICS, SPECIAL CENTRES)", "WELLNESS & FITNESS (MEDITATION CENTRES, MARTIAL ARTS CENTRES, TRACK & FIELD AUDITORIUMS, SPAS, GYMS, STORES)"],
        "EDUCATIONAL": ["PUBLIC & PRIVATE SERVICES (DAY CARE, KINDERGARTEN/PRE-SCHOOL, PRIMARY, SECONDARY, TERTIARY-COMMUNITY COLLEGES/UNIVERSITIES, INFIRMARIES, TRAINING CENTRES, COMMUNITY CENTRES)"],
        "COMMUNICATIONS": ["INTERNET (WEB DEVELOPMENT & NETWORK, CAFES, INSTALLATIONS, SERVICING & REPAIRS, MARKETING/PROMOTIONS, TRAINING, LIBRARY SERVICES)", "TELEPHONY (CELL, LAND)", "MEDIA NEWS (PRINT, ELECTRONIC, MULTIMEDIA)"],
        "AUDIO/VISUAL": ["PHOTO STUDIO SERVICES (FREELANCE, STUDIO PROCESSING)", "GRAPHIC DESIGNS", "MUSICAL STUDIOS", "VENUE/EVENTS PLANNING MANAGEMENT SERVICES (THEATRICAL PRODUCTIONS, STAGE & LIGHT PRODUCTION SERVICES, STAGE SHOW COORDINATION, BANQUETING & WEDDING PRODUCTIONS, DECOR DESIGNS & PLANNING SERVICES)"],
        "FINANCES GENERAL": ["LOCAL AND INTERNATIONAL INSTITUTIONS (COMMERCIAL BANKING, INSURANCE, INVESTMENTS, LOAN FIRMS)"],
        "NGO/SERVICE CLUBS": ["LOCAL (COMMUNITY, NATIONAL)", "INTERNATIONAL (LIONS, KIWANIS, ROTARY, FOOD FOR THE POOR, SALVATION ARMY)"],
        "RELIGIOUS": ["CENTRES & BRANCHES (CHRISTIAN, MOSLEM, BUDDHIST, BAHI, NON-DENOMINATIONAL & OTHERS)"]
    },
    "ROOMS & VENUE - RENTALS AND REAL ESTATES SALES": {
        "ACCOMMODATIONS": ["RESORT/LEISURE (HOTELS, LARGE RESORTS, BOUTIQUE RESORTS, GUESTS HOUSES/VILLAS/COTTAGES, CONVALESCENCE HOMES)", "CONVENTIONAL (MEETINGS/CONFERENCES, HOTELS, CENTRES, PARKS, OTHER LOCATIONS)"],
        "RENTAL, LEASE & SALES": ["RESIDENTIAL (HOMES, APARTMENTS, LOTS)", "COMMERCIAL (OFFICES, STORES, PLAZAS, COMPLEXES, WAREHOUSES & STORAGE ZONED AREAS)", "VENUE RENTAL (ENTERTAINMENT & BUSINESS, NON-SERVICED LOTS, PARKS, ENTERTAINMENT ZONED AREAS, ATTRACTION SPOTS, FULL SERVICED LOCATIONS WITH F&B OUTLETS)"]
    },
    "FARMING": {
        "AGRICULTURE": ["FISHERIES (FRESH WATER FARMS/SUPPLIERS, OCEAN FARMS/SUPPLIERS)", "HERBS & SPICES", "POULTRY", "CATTLE", "VEGETABLE", "FRUITS", "GROUND PROVISIONS", "HORTICULTURE (FLORAL FARMERS & SUPPLIERS)", "ALL/GENERAL"]
    },
    "RETAIL & WHOLESALE TRADE": {
        "SHOPPING": ["STORE OUTLETS (SUPERMARKETS, FLORAL ARRANGEMENT STORES, ELECTRONIC STORES, PHARMACEUTICAL, HEALTH FOOD & BEVERAGE SUPPLIES, BOOK STORES/CLUBS, CONVENIENCE/COMMISSARIES, HARDWARE & CONSTRUCTION SUPPLIES, COMMERCIAL EQUIPMENTS & DEVICES)", "MARKETS & STALLS (CRAFT MARKETS, FOOD & BEVERAGE)"],
        "PURVEYORS": ["PROCESSED/MANUFACTURED GOODS (COMMODITIES, NON-FOODS, CLOTHING, CHEMICALS)"]
    },
    "FOOD & BEVERAGE": {
        "DINING OUTLETS": ["BARS", "RESTAURANTS (FULL SERVICE, CAFES, DELIS)"],
        "TO GO OUTLETS": ["BARS", "RESTAURANTS & REST STOPS (FULL SERVICE, CAFES, DELIS, DRIVE THROUGH)"]
    },
    "EVENTS & ENTERTAINMENT": {
        "SCHEDULES": ["LIVE SHOWS / FESTIVALS/ PARTIES/ SPORTING EVENTS (ANNUAL, MONTHLY, SPECIAL/SEASONAL, DAILY/NIGHTLY, LOCAL THEMES, INTERNATIONAL THEMES)"],
        "PLACES/VENUES": ["CLUBS/ PARTIES/ CINEMAS/ ARENAS/ PARKS (ADULT, GENERAL, SPECIAL/SEASONAL)"]
    },
    "JOBS & CAREERS": {
        "OPPORTUNITIES": ["FULL-TIME", "PART-TIME", "CONTRACT", "FREELANCE", "INTERNSHIP"]
    }
};

const LEGACY_TO_CURRENT_CATEGORY = Object.freeze({
    "SERVICES": "GENERAL",
    "ROOMS & VENUE": "REAL ESTATE",
    "ROOMS & VENUE - RENTALS AND REAL ESTATES SALES": "REAL ESTATE",
    "RETAIL & WHOLESALE TRADE": "REAL ESTATE",
    "FARMING": "FARMING & AGRICULTURE",
    "EVENTS & ENTERTAINMENT": "ENTERTAINMENT",
    "AUTO CARE": "AUTO CARE SERVICES",
    "JOBS & CAREERS": null
});

window.TAXONOMY = TAXONOMY;
window.TAXONOMY_LEGACY = LEGACY_TAXONOMY;
window.TAXONOMY_LEGACY_TO_CURRENT = LEGACY_TO_CURRENT_CATEGORY;
window.TAXONOMY_SOURCE = Object.freeze({
    version: "2026-client-recategorization",
    revisedDocument: "CATEGORIES & SUBS-2026-UsseHub - Listing.docx",
    regroupedDocument: "ver2 -CATEGORIES & SUBS-2026-UsseHub - Listing.docx",
    interactionPrototype: "Test 3b - Categorize -Untitled.html",
    interactionPrototypeExport: "Category testing -DOCTYPE html.htm.html"
});

window.getCurrentCategoryForLegacy = function(category) {
    if (Object.prototype.hasOwnProperty.call(LEGACY_TO_CURRENT_CATEGORY, category)) {
        return LEGACY_TO_CURRENT_CATEGORY[category];
    }
    return Object.prototype.hasOwnProperty.call(TAXONOMY, category) ? category : null;
};

window.getCategoryFilterValues = function(category) {
    const values = new Set([category]);
    Object.entries(LEGACY_TO_CURRENT_CATEGORY).forEach(([legacy, current]) => {
        if (current === category) values.add(legacy);
    });
    return Array.from(values).filter(Boolean);
};

window.getLabelsForCategory = function(category) {
    const currentCategory = window.getCurrentCategoryForLegacy(category) || category;

    switch (currentCategory) {
        case "REAL ESTATE":
            return {
                name: "Property / Venue / Business Name*",
                subcat: "Secondary Category*",
                loc: "Property / Business Location*",
                desc: "Property, Venue or Business Details*"
            };
        case "PROPERTY MANAGEMENT SERVICES":
            return {
                name: "Property Management Business Name*",
                subcat: "Secondary Category*",
                loc: "Service Location*",
                desc: "Property Management Services*"
            };
        case "FINANCIAL SERVICES":
            return {
                name: "Financial Institution / Business Name*",
                subcat: "Secondary Category*",
                loc: "Institution / Service Location*",
                desc: "Financial Services Description*"
            };
        case "NGO / SERVICE CLUBS":
            return {
                name: "Organization / Club Name*",
                subcat: "Secondary Category*",
                loc: "Organization Location*",
                desc: "Organization Purpose & Services*"
            };
        case "FOOD & BEVERAGE":
            return {
                name: "Restaurant / Outlet / Distributor Name*",
                subcat: "Secondary Category*",
                loc: "Business Location*",
                desc: "Menu, Products or Services*"
            };
        case "FARMING & AGRICULTURE":
            return {
                name: "Farm / Agriculture Business Name*",
                subcat: "Secondary Category*",
                loc: "Farm / Business Location*",
                desc: "Produce, Livestock or Services*"
            };
        case "CONSTRUCTION":
            return {
                name: "Construction Business / Contractor Name*",
                subcat: "Secondary Category*",
                loc: "Service Location*",
                desc: "Construction Services & Expertise*"
            };
        case "AUTO CARE SERVICES":
            return {
                name: "Auto Care Business Name*",
                subcat: "Secondary Category*",
                loc: "Business Location*",
                desc: "Auto Care Services*"
            };
        case "ENTERTAINMENT":
            return {
                name: "Event / Venue / Entertainment Business Name*",
                subcat: "Secondary Category*",
                loc: "Event / Venue Location*",
                desc: "Event, Venue or Entertainment Details*"
            };
        case "JOBS & CAREERS":
            return {
                name: "Company Name*",
                subcat: "Secondary Category*",
                loc: "Job Location / Remote*",
                desc: "Job Description & Requirements*"
            };
        case "GENERAL":
        default:
            return {
                name: "Business / Service Name*",
                subcat: "Secondary Category*",
                loc: "Location (Parish/Town)*",
                desc: "Business Description*"
            };
    }
};

function appendOption(parent, value, label, options = {}) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    if (options.hidden) option.hidden = true;
    if (options.disabled) option.disabled = true;
    if (options.level) option.dataset.taxonomyLevel = options.level;
    parent.appendChild(option);
    return option;
}

function groupDetails(group) {
    if (Array.isArray(group)) {
        return { tertiary: group, specific: [], notes: [], qualifiers: [] };
    }

    return {
        tertiary: Array.isArray(group?.tertiary) ? group.tertiary : [],
        specific: Array.isArray(group?.specific) ? group.specific : [],
        notes: Array.isArray(group?.notes) ? group.notes : [],
        qualifiers: Array.isArray(group?.qualifiers) ? group.qualifiers : []
    };
}

function appendTaxonomyGroups(select, groups, options = {}) {
    Object.entries(groups || {}).forEach(([groupName, rawGroup]) => {
        const details = groupDetails(rawGroup);

        if (details.tertiary.length) {
            const tertiaryGroup = document.createElement("optgroup");
            tertiaryGroup.label = groupName;
            details.tertiary.forEach((item) => {
                appendOption(tertiaryGroup, `${groupName} - ${item}`, item, {
                    hidden: options.hidden,
                    level: "tertiary"
                });
            });
            select.appendChild(tertiaryGroup);
        }

        if (details.specific.length) {
            const specificGroup = document.createElement("optgroup");
            specificGroup.label = `${groupName} - Specific items / sub-types`;
            details.specific.forEach((item) => {
                appendOption(specificGroup, `${groupName} - ${item}`, item, {
                    hidden: options.hidden,
                    level: "specific"
                });
            });
            select.appendChild(specificGroup);
        }

        [...details.notes, ...details.qualifiers].forEach((note) => {
            appendOption(select, "", `${details.qualifiers.includes(note) ? "Applies to" : "Note"}: ${note}`, {
                hidden: options.hidden,
                disabled: true,
                level: "context"
            });
        });
    });
}

window.populateCategorySelect = function(selectElementId) {
    const select = document.getElementById(selectElementId);
    if (!select) return;

    const previousValue = select.value;
    select.replaceChildren();
    appendOption(select, "", "Select Category");

    Object.keys(TAXONOMY).forEach((mainCategory) => {
        appendOption(select, mainCategory, mainCategory);
    });

    new Set([...Object.keys(LEGACY_TAXONOMY), ...Object.keys(LEGACY_TO_CURRENT_CATEGORY)]).forEach((legacyCategory) => {
        if (Object.prototype.hasOwnProperty.call(TAXONOMY, legacyCategory)) return;
        appendOption(select, legacyCategory, `${legacyCategory} (legacy)`, { hidden: true });
    });

    if (previousValue && Array.from(select.options).some((option) => option.value === previousValue)) {
        select.value = previousValue;
    }
};

function resetTaxonomySelect(select, placeholder, disabled = false) {
    if (!select) return;
    select.replaceChildren();
    appendOption(select, "", placeholder);
    select.disabled = disabled;
}

function taxonomyGroupsFor(category) {
    const currentCategory = window.getCurrentCategoryForLegacy(category);
    return TAXONOMY[category] || LEGACY_TAXONOMY[category] || TAXONOMY[currentCategory] || null;
}

function ensureExistingTaxonomyOption(select, value) {
    if (!select || !value || Array.from(select.options).some((option) => option.value === value)) return;
    appendOption(select, value, `${value} (existing value)`);
}

window.populateSubcategorySelect = function(categorySelectId, subcategorySelectId, tertiarySelectId, specificSelectId) {
    const categorySelect = document.getElementById(categorySelectId);
    const subSelect = document.getElementById(subcategorySelectId);
    if (!categorySelect || !subSelect) return;

    const selectedCategory = categorySelect.value;
    const currentGroups = TAXONOMY[selectedCategory];
    const legacyGroups = LEGACY_TAXONOMY[selectedCategory];

    // New listing/admin forms provide all four client-requested levels.
    if (tertiarySelectId) {
        resetTaxonomySelect(subSelect, "Select Secondary Category", true);
        resetTaxonomySelect(document.getElementById(tertiarySelectId), "Choose a secondary category first", true);
        resetTaxonomySelect(document.getElementById(specificSelectId), "Choose a specialization first", true);

        const groups = taxonomyGroupsFor(selectedCategory);
        if (!groups) return;
        Object.keys(groups).forEach((groupName) => appendOption(subSelect, groupName, groupName, { level: "secondary" }));
        subSelect.disabled = false;
        return;
    }

    // Backward-compatible two-field forms receive a flattened list.
    resetTaxonomySelect(subSelect, "Select Subcategory (Optional)");

    if (currentGroups) {
        appendTaxonomyGroups(subSelect, currentGroups);

        // FOOD & BEVERAGE exists in both versions. Preserve historical values
        // invisibly so existing records do not go blank when an admin edits one.
        if (legacyGroups) appendTaxonomyGroups(subSelect, legacyGroups, { hidden: true });
    } else if (legacyGroups) {
        appendTaxonomyGroups(subSelect, legacyGroups);
    }

    subSelect.disabled = !currentGroups && !legacyGroups;
};

window.populateTertiarySelect = function(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId) {
    const category = document.getElementById(categorySelectId)?.value || "";
    const secondary = document.getElementById(secondarySelectId)?.value || "";
    const tertiarySelect = document.getElementById(tertiarySelectId);
    const specificSelect = document.getElementById(specificSelectId);
    resetTaxonomySelect(tertiarySelect, "Select Tertiary Category", true);
    resetTaxonomySelect(specificSelect, "Choose a specialization first", true);

    const rawGroup = taxonomyGroupsFor(category)?.[secondary];
    if (!rawGroup || !tertiarySelect) return;
    const details = groupDetails(rawGroup);
    details.tertiary.forEach((item) => appendOption(tertiarySelect, item, item, { level: "tertiary" }));
    tertiarySelect.disabled = details.tertiary.length === 0;
};

window.populateSpecificSelect = function(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId) {
    const category = document.getElementById(categorySelectId)?.value || "";
    const secondary = document.getElementById(secondarySelectId)?.value || "";
    const tertiary = document.getElementById(tertiarySelectId)?.value || "";
    const specificSelect = document.getElementById(specificSelectId);
    resetTaxonomySelect(specificSelect, "Select Specific Type / Context (Optional)", true);

    const rawGroup = taxonomyGroupsFor(category)?.[secondary];
    if (!rawGroup || !tertiary || !specificSelect) return;
    const details = groupDetails(rawGroup);
    const choices = [...details.specific, ...details.qualifiers];
    choices.forEach((item) => appendOption(specificSelect, item, item, { level: "specific" }));
    specificSelect.disabled = choices.length === 0;
};

window.getClassificationValue = function(secondarySelectId, tertiarySelectId, specificSelectId) {
    return [secondarySelectId, tertiarySelectId, specificSelectId]
        .map((id) => document.getElementById(id)?.value?.trim() || "")
        .filter(Boolean)
        .join(" › ");
};

window.restoreClassification = function(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId, storedValue) {
    window.populateSubcategorySelect(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId);
    if (!storedValue) return;

    const category = document.getElementById(categorySelectId)?.value || "";
    const groups = taxonomyGroupsFor(category);
    const secondarySelect = document.getElementById(secondarySelectId);
    const tertiarySelect = document.getElementById(tertiarySelectId);
    const specificSelect = document.getElementById(specificSelectId);

    let parts = String(storedValue).split(/\s+›\s+/).filter(Boolean);
    if (parts.length === 1 && groups) {
        const oldValue = parts[0];
        const secondary = Object.keys(groups).find((groupName) => oldValue === groupName || oldValue.startsWith(`${groupName} - `));
        if (secondary) {
            const remainder = oldValue.slice(secondary.length).replace(/^\s*-\s*/, "");
            parts = [secondary, remainder].filter(Boolean);
        }
    }

    const secondary = parts[0];
    ensureExistingTaxonomyOption(secondarySelect, secondary);
    if (secondarySelect) {
        secondarySelect.disabled = false;
        secondarySelect.value = secondary;
    }
    window.populateTertiarySelect(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId);

    if (parts[1] && tertiarySelect) {
        ensureExistingTaxonomyOption(tertiarySelect, parts[1]);
        tertiarySelect.disabled = false;
        tertiarySelect.value = parts[1];
        window.populateSpecificSelect(categorySelectId, secondarySelectId, tertiarySelectId, specificSelectId);
    }
    if (parts.length > 2 && specificSelect) {
        const specific = parts.slice(2).join(" › ");
        ensureExistingTaxonomyOption(specificSelect, specific);
        specificSelect.disabled = false;
        specificSelect.value = specific;
    }
};
