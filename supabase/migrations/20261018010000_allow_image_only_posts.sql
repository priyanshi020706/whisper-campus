begin;

-- An image can be a complete post without a caption. Text-only posts still
-- require 1-2000 non-whitespace characters; captions remain capped at 2000.
alter table public.posts
  drop constraint if exists posts_content_check;

alter table public.posts
  add constraint posts_content_check
  check (
    (
      image_path is not null
      and char_length(btrim(content)) between 0 and 2000
    )
    or
    (
      image_path is null
      and char_length(btrim(content)) between 1 and 2000
    )
  );

commit;
