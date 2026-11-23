CREATE OR REPLACE FUNCTION staging.hash_key(VARIADIC p text[]) RETURNS varchar(32)
LANGUAGE plpgsql IMMUTABLE 
AS $$
BEGIN
	RETURN md5(array_to_string(
		ARRAY(
			SELECT 
				coalesce(x, '~NULL~') 
			FROM 
				unnest(p) 
			WITH 
				ORDINALITY t(x, i) 
			ORDER BY i), '||'));
END;
$$;
