#ifndef CURL_OPTS_H
#define CURL_OPTS_H
// Define functions
static void curl_opts_set_on(CURL *curl_ez_handle, Jsonb *curlOpts) {
    JsonbIteratorToken jbItk;
    JsonbValue  jbV;
    JsonbIterator *jbIt;

    if (!JB_ROOT_IS_OBJECT(curlOpts))
      ereport(ERROR, errmsg("curlOpts is not an object"));

    jbIt = JsonbIteratorInit(&curlOpts->root);
    jbItk = JsonbIteratorNext(&jbIt, &jbV, true);

    if (jbItk != WJB_BEGIN_OBJECT)
      ereport(ERROR, errmsg("curlOpts is not an object?"));

    while ((jbItk = JsonbIteratorNext(&jbIt, &jbV, true)) != WJB_DONE)
    {
        // first, key
        if (jbItk != WJB_KEY)
            continue;
        CURLoption key;
        switch (jbV.type)
        {
            case jbvString: {
                key = (CURLoption) strtol(jbV.val.string.val, NULL, 10);
                break;
            }
            case jbvNumeric: {
                key = (CURLoption) DatumGetInt32(NumericGetDatum(jbV.val.numeric));
                break;
            }
            default:
			    elog(ERROR, "curlOpts unrecognized jsonb key type: %d", (int) jbV.type);
        }

        elog(NOTICE, "curlOpts key: %s = %d", (jbV.val.string.val), key);

        // then, value
        if ((jbItk = JsonbIteratorNext(&jbIt, &jbV, true)) != WJB_VALUE)
            elog(ERROR, "curlOpts unexpected jsonb token: %d", jbItk);

        switch (jbV.type)
        {
            case jbvBool: {
                CURL_EZ_SETOPT(curl_ez_handle, key, jbV.val.boolean);
                break;
            }
            case jbvString: {
                CURL_EZ_SETOPT(curl_ez_handle, key, jbV.val.string.val);
                break;
            }
            case jbvNumeric: {
                // long
                CURL_EZ_SETOPT(curl_ez_handle, key, (long) DatumGetInt32(NumericGetDatum(jbV.val.numeric)));
                break;
            }
            default:
			    elog(ERROR, "curlOpts unrecognized jsonb value type: %d", (int) jbV.type);
        }

    }

}


// End define functions
#endif
