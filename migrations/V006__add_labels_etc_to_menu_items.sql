alter table menu_items
    add labels jsonb;

comment on column menu_items.labels is 'spicy?: boolean;   vegetarian?: boolean;   vegan?: boolean;   kosher?: boolean;   glutenFree?: boolean;   lactoseFree?: boolean;   halal?: boolean;';

alter table menu_items
    add portions jsonb;

comment on column menu_items.portions is 'weightGrams?: number;   volumeMl?: number;   pieces?: number;   description?: string;';

alter table menu_items
    add nutrition jsonb;

comment on column menu_items.nutrition is 'calories?: number;   protein?: number;   fat?: number;   carbs?: number;';

alter table menu_items
    add spicy_level smallint CHECK (spicy_level BETWEEN 0 AND 3);

