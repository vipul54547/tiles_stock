-- Expose Punch Look as a facet too, same opt-in as Series (both are
-- own-naming, no-admin-mapping single-select free-text DNA attributes).
update dna_attributes set show_in_facets = true where name = 'Punch Look';
