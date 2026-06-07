const TAXONOMY = {
    "SERVICES": {
        "GENERAL": ["TRANSPORT (RENTALS, LEASE, CHARTERS)", "MAINTENANCE (PAINTING, CARPENTRY, CARPET CLEANING, CAR CARE CENTRES)", "REPAIRS (AUTO GARAGES, ELECTRONIC, HOMES & OFFICES, MACHINERY)", "CONSTRUCTION (RESIDENTIAL, COMMERCIAL, FIXTURES)", "DELIVERY/PICKUPS (FOODS, NON-FOODS)", "CATERING (LOW BUDGET/SMALL EVENTS, GENERAL-MODERATE/LARGE EVENTS)"],
        "HEALTH & WELLNESS": ["MEDICAL (CLINICS, SPECIAL CENTRES)", "WELLNESS & FITNESS (MEDITATION CENTRES, MARTIAL ARTS CENTRES, TRACK & FIELD AUDITORIUMS, SPAS, GYMS, STORES)"],
        "EDUCATIONAL": ["PUBLIC & PRIVATE SERVICES (DAY CARE, KINDERGARTEN/PRE-SCHOOL, PRIMARY, SECONDARY, TERTIARY-COMMUNITY COLLEGES/UNIVERSITIES, INFIRMARIES, TRAINING CENTRES, COMMUNITY CENTRES)"],
        "COMMUNICATIONS": ["INTERNET (WEB DEVELOPMENT & NETWORK, CAFES, INSTALLATIONS, SERVICING & REPAIRS, MARKETING/PROMOTIONS, TRAINING, LIBRARY SERVICES)", "TELEPHONY (CELL, LAND)", "MEDIA NEWS (PRINT, ELECTRONIC, MULTIMEDIA)"],
        "AUDIO/VISUAL": ["PHOTO STUDIO SERVICES (FREELANCE, STUDIO PROCESSING)", "GRAPHIC DESIGNS", "MUSICAL STUDIOS", "VENUE/EVENTS PLANNING MANAGEMENT SERVICES (THEATRICAL PRODUCTIONS, STAGE & LIGHT PRODUCTION SERVICES, STAGE SHOW COORDINATION, BANQUETING & WEDDING PRODUCTIONS, DÉCOR DESIGNS & PLANNING SERVICES)"],
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

window.TAXONOMY = TAXONOMY;

window.getLabelsForCategory = function(category) {
    switch (category) {
        case 'JOBS & CAREERS':
            return {
                name: 'Company Name*',
                subcat: 'Job Type',
                loc: 'Job Location / Remote*',
                desc: 'Job Description & Requirements*'
            };
        case 'ROOMS & VENUE - RENTALS AND REAL ESTATES SALES':
            return {
                name: 'Property / Venue Name*',
                subcat: 'Property Type',
                loc: 'Property Location*',
                desc: 'Property Details & Amenities*'
            };
        case 'FARMING':
            return {
                name: 'Farm / Business Name*',
                subcat: 'Produce / Farm Type',
                loc: 'Farm Location*',
                desc: 'Produce / Service Description*'
            };
        case 'RETAIL & WHOLESALE TRADE':
            return {
                name: 'Store / Business Name*',
                subcat: 'Store / Product Type',
                loc: 'Store Location*',
                desc: 'Products / Services Description*'
            };
        case 'FOOD & BEVERAGE':
            return {
                name: 'Restaurant / Outlet Name*',
                subcat: 'Outlet Type',
                loc: 'Outlet Location*',
                desc: 'Menu / Outlet Description*'
            };
        case 'EVENTS & ENTERTAINMENT':
            return {
                name: 'Event / Venue Name*',
                subcat: 'Event / Venue Type',
                loc: 'Event Location*',
                desc: 'Event Details / Venue Description*'
            };
        case 'SERVICES':
        default:
            return {
                name: 'Business / Service Name*',
                subcat: 'Subcategory',
                loc: 'Location (Parish/Town)*',
                desc: 'Business Description*'
            };
    }
};

window.populateCategorySelect = function(selectElementId) {
    const select = document.getElementById(selectElementId);
    if (!select) return;
    select.innerHTML = '<option value="">Select Category</option>';
    for (const mainCategory in TAXONOMY) {
        const option = document.createElement('option');
        option.value = mainCategory;
        option.textContent = mainCategory;
        select.appendChild(option);
    }
};

window.populateSubcategorySelect = function(categorySelectId, subcategorySelectId) {
    const categorySelect = document.getElementById(categorySelectId);
    const subSelect = document.getElementById(subcategorySelectId);
    if (!categorySelect || !subSelect) return;
    
    subSelect.innerHTML = '<option value="">Select Subcategory (Optional)</option>';
    
    const selectedCategory = categorySelect.value;
    if (!selectedCategory || !TAXONOMY[selectedCategory]) return;
    
    const groups = TAXONOMY[selectedCategory];
    for (const groupName in groups) {
        const optgroup = document.createElement('optgroup');
        optgroup.label = groupName;
        
        groups[groupName].forEach(item => {
            const option = document.createElement('option');
            option.value = groupName + ' - ' + item;
            option.textContent = item;
            optgroup.appendChild(option);
        });
        subSelect.appendChild(optgroup);
    }
};
